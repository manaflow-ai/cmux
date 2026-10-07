import CmuxLink

extension BenchRunner {
    /// Injects `fault` on a warm link, sends one echo at once, and times the
    /// fault-to-echo interval.
    func recovery(_ fault: RecoveryFault) async throws -> RecoveryResult {
        var samples: [Double] = []
        var failures = 0
        var reconnected: [Bool] = []
        var paths: [String] = []
        for _ in 0..<spec.recoverySamples {
            let outcome = try await withFixture { fixture -> (Double?, Bool, String) in
                let echo = try await EchoChannel.open(on: fixture)
                guard try await echo.ping() != nil else { throw BenchError.timeout("warm echo") }
                let states = await fixture.dialer.states()
                let watcher = Task { () -> Bool in
                    for await state in states {
                        if case .reconnecting = state { return true }
                        if state.isClosed { return false }
                    }
                    return false
                }
                let start = clock.now
                let injected = switch fault {
                case .drop: await rig.dropTransports()
                case .roam: await rig.roam(to: .turn)
                }
                guard injected else { throw BenchError.setup("rig cannot inject \(fault.rawValue)") }
                let answered = try await echo.ping(limit: .seconds(20)) != nil
                let elapsed = clock.now - start
                watcher.cancel()
                let sawReconnect = await watcher.value
                let path = await fixture.dialer.state.path.map { "\($0.kind)" } ?? "none"
                await echo.close()
                return (answered ? elapsed.milliseconds : nil, sawReconnect, path)
            }
            if let value = outcome.0 { samples.append(value) } else { failures += 1 }
            reconnected.append(outcome.1)
            paths.append(outcome.2)
        }
        return RecoveryResult(
            fault: fault.rawValue,
            recovered: Distribution(milliseconds: samples),
            samples: samples,
            failures: failures,
            sessionReconnected: reconnected,
            pathAfter: paths
        )
    }
}
