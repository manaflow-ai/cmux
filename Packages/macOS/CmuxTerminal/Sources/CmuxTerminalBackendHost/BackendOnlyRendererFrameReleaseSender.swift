internal import CmuxTerminalBackend

func sendBackendOnlyRendererFrameRelease(
    _ release: BackendRendererFrameRelease,
    through session: BackendCanonicalSession,
    deadline: Duration,
    clock: any Clock<Duration>
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            do {
                _ = try await session.releaseRendererFrame(release)
                return true
            } catch {
                return false
            }
        }
        group.addTask {
            do {
                try await clock.sleep(for: deadline, tolerance: nil)
            } catch {
                return false
            }
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
