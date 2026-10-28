public import Foundation

// The launch check of the kept update: its blocking read, which the app runs as a
// launch read on a lane from `main`, and the decision ``WebUpdater/launchTree()`` makes with the
// followed channel.
extension WebUpdater {
    /// The kept update as it is on disk: `state.json` and, when its active update suits this app,
    /// that update's folder checked against its signed digest. ``launchTree()`` decides with the
    /// followed channel whether it is served.
    nonisolated public struct Kept: Sendable, Equatable {
        /// `state.json` as it was read.
        public let state: WebUpdateState
        /// The active update's folder; nil when there is none, it is for other native code or not
        /// newer than the bundled web, or its files changed on disk.
        public let tree: URL?
    }

    /// Reads ``Kept``. It blocks on files (the digest reads every file of the kept update).
    public nonisolated static func readKept(store: WebUpdateStore, app: App) -> Kept {
        let state = store.readState()
        guard let active = state.active, active.abi == app.abi, active.committedAt > app.webBuiltAt else {
            return Kept(state: state, tree: nil)
        }
        return Kept(state: state, tree: store.verifiedTree(active))
    }

    @concurrent nonisolated static func readKeptOffMain(store: WebUpdateStore, app: App) async -> Kept {
        readKept(store: store, app: app)
    }

    /// `channel` is the followed `updates.web` (nil before it is read: any kept update).
    @concurrent nonisolated static func launchCheck(store: WebUpdateStore, app: App, channel: Channel? = nil) async -> (URL?, WebUpdateState) {
        await launchCheck(readKept(store: store, app: app), store: store, channel: channel)
    }

    /// Serves `kept`'s folder when `channel` (nil: any) published it, else forgets the kept update.
    @concurrent nonisolated static func launchCheck(_ kept: Kept, store: WebUpdateStore, channel: Channel?) async -> (URL?, WebUpdateState) {
        var state = kept.state
        guard let active = state.active else { return (nil, state) }
        let followed = channel.map { $0 != .off && active.channel == $0.rawValue } ?? true
        if followed, let tree = kept.tree { return (tree, state) }
        // Web updates are off or follow another channel, a newer app shipped newer web, or the
        // tree changed on disk: serve the bundle.
        state.active = nil
        state.previous = nil
        try? store.write(state)
        store.prune(keeping: [])
        return (nil, state)
    }
}
