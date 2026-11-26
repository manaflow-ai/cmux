import Darwin
import Dispatch
import Foundation

/// Event-driven readiness signal for one Computer Use daemon process.
///
/// The driver writes its PID file only after its Unix listener has bound.
/// Watching that exact file avoids polling and avoids relying on parent
/// directory events, which macOS does not consistently emit for Unix sockets.
struct ComputerUseDaemonReadiness: Sendable {
    let pidFileURL: URL
    let timeout: Duration

    func prepare() -> Bool {
        let path = pidFileURL.path
        var descriptor = Darwin.open(
            path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        if descriptor < 0, errno == EEXIST {
            descriptor = Darwin.open(
                path,
                O_WRONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            metadata.st_uid == geteuid(),
            metadata.st_nlink == 1,
            Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
            Darwin.ftruncate(descriptor, 0) == 0
        else {
            return false
        }
        return true
    }

    func waitUntilReady(
        _ isReady: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await wait(until: isReady)
    }

    func waitUntilStopped(
        _ isListening: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await wait {
            !(await isListening())
        }
    }

    private func wait(
        until condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        if await condition() { return true }
        let events = fileEvents()
        if await condition() { return true }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    guard !Task.isCancelled else { return false }
                    if await condition() { return true }
                }
                return await condition()
            }
            group.addTask {
                // Genuine upper deadline; readiness is driven by the PID-file event.
                try? await ContinuousClock().sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func fileEvents() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let descriptor = Darwin.open(
                pidFileURL.path,
                O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }

            var metadata = stat()
            guard
                Darwin.fstat(descriptor, &metadata) == 0,
                (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                metadata.st_uid == geteuid(),
                metadata.st_nlink == 1,
                (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
            else {
                Darwin.close(descriptor)
                continuation.finish()
                return
            }

            // DispatchSource is the system's exact event source for vnode writes.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }
}
