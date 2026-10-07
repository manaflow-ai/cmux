extension BenchRunner {
    /// Fresh endpoints per sample; `firstByte` = connect to live, plus opening
    /// a channel and one echo.
    func coldConnect() async throws -> ColdConnectResult {
        var live: [Double] = []
        var firstByte: [Double] = []
        for _ in 0..<spec.connectSamples {
            let sample = try await withFixture { fixture -> (Double, Double) in
                let start = clock.now
                let echo = try await EchoChannel.open(on: fixture)
                guard try await echo.ping() != nil else { throw BenchError.timeout("first echo") }
                let afterLive = clock.now - start
                await echo.close()
                return (fixture.connectToLive.milliseconds, (fixture.connectToLive + afterLive).milliseconds)
            }
            live.append(sample.0)
            firstByte.append(sample.1)
        }
        return ColdConnectResult(
            connectToLive: Distribution(milliseconds: live),
            firstByte: Distribution(milliseconds: firstByte),
            firstByteSamples: firstByte
        )
    }
}
