public import CmuxNextTrace

extension CEFTracing {
    /// ``start()`` as `trace.start`'s `chromium` member: the process that records and the clock offset, or why
    /// none does.
    public func startReport() async -> ChromiumTraceReport {
        do throws(CEFTracingError) {
            return try await Self.report(start())
        } catch {
            return Self.report(error)
        }
    }

    /// ``stop()`` as `trace.stop`'s `chromium` member: the JSON trace and meta.json, or why there is none.
    public func stopReport() async -> ChromiumTraceReport {
        do throws(CEFTracingError) {
            return try await Self.report(stop())
        } catch {
            return Self.report(error)
        }
    }

    static func report(_ started: Started) -> ChromiumTraceReport {
        ChromiumTraceReport(state: .recording, mode: started.mode.rawValue, categories: started.categories,
                            offsetNanos: started.clock?.offsetNanos, errorBoundNanos: started.clock?.errorBoundNanos)
    }

    static func report(_ stopped: Stopped) -> ChromiumTraceReport {
        ChromiumTraceReport(state: .stopped, mode: stopped.mode.rawValue, path: stopped.path, metaPath: stopped.metaPath,
                            offsetNanos: stopped.clock?.offsetNanos, errorBoundNanos: stopped.clock?.errorBoundNanos)
    }

    /// The error's ``CEFTracingError/code``; an unsupported Chromium is untraced and says why in `detail`.
    static func report(_ error: CEFTracingError) -> ChromiumTraceReport {
        guard case .unsupported(let reason) = error else { return ChromiumTraceReport(state: .error, error: error.code) }
        return ChromiumTraceReport(state: .untraced, error: error.code, detail: reason.rawValue)
    }
}
