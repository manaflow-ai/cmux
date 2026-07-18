import AppKit

/// Injected registry that lets app-owned Ghostty host views mount thin compositors.
@MainActor
final class TerminalBackendPresentationRegistry {
    private var mounts: [UUID: TerminalBackendPresentationMount] = [:]

    func register(surfaceID: UUID) -> TerminalBackendPresentationMount {
        if let existing = mounts[surfaceID] { return existing }
        let mount = TerminalBackendPresentationMount(surfaceID: surfaceID)
        mounts[surfaceID] = mount
        return mount
    }

    func unregister(_ mount: TerminalBackendPresentationMount) {
        guard mounts[mount.surfaceID] === mount else { return }
        mounts.removeValue(forKey: mount.surfaceID)
        mount.invalidate()
    }

    @discardableResult
    func mountCompositor(surfaceID: UUID, in hostView: NSView) -> Bool {
        guard let mount = mounts[surfaceID] else { return false }
        mount.mount(in: hostView)
        return true
    }

    func unmountCompositor(surfaceID: UUID, from hostView: NSView? = nil) {
        mounts[surfaceID]?.unmount(from: hostView)
    }

    func compositorView(surfaceID: UUID) -> NSView? {
        mounts[surfaceID]?.compositorView
    }
}
