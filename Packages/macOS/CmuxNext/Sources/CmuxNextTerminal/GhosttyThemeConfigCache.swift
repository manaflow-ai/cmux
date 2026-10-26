/// The user's config with one theme applied, per theme name (``GhosttyRuntime/themeConfig(named:)``): each one is
/// built on the config loader, off the main thread, and cached when it lands. A config change
/// (``invalidate(loader:inputs:)``) keeps serving each name's last config while its rebuild runs and swaps it when
/// the rebuild lands, so a themed terminal never shows the inherited theme for a frame (stale-while-revalidate, as
/// Chrome's HTTP cache serves a stale entry during its async revalidation, net/http/http_cache_transaction.cc). Only
/// a name never built returns nil.
final class GhosttyThemeConfigCache {
    private struct Entry {
        /// The last config that landed for the name; stale while `builtEpoch` is behind the cache's.
        var config: GhosttyThemeConfig?
        /// The config generation the last landed build belongs to (a failed build counts, so it is not retried).
        var builtEpoch: Int?
        /// The config generation of the build in flight.
        var requestedEpoch: Int?
        /// Asked for since its last build landed. The handlers run on a landing, so an owner still on the theme asks
        /// again; a config change drops a name nobody asked for since.
        var asked = true
    }

    private var entries: [String: Entry] = [:]
    /// Bumps on every config change.
    private var epoch = 0
    private var handlers: [@MainActor () -> Void] = []

    /// Runs `handler` each time a build lands and is cached.
    func addHandler(_ handler: @escaping @MainActor () -> Void) {
        handlers.append(handler)
    }

    /// The user's config changed: every name asked for since its last build landed rebuilds on `loader` and keeps
    /// serving its current config until the rebuild lands; the other names are dropped. With no loader nothing can
    /// rebuild, so every name is dropped.
    ///
    /// - Parameters:
    ///   - loader: Where the rebuilds run.
    ///   - inputs: Each name's build snapshot, taken now on the main actor.
    func invalidate(loader: (any GhosttyConfigLoading)?, inputs: (String) -> GhosttyConfigInputs) {
        epoch &+= 1
        guard let loader else {
            entries.removeAll()
            return
        }
        entries = entries.filter { $0.value.asked }
        for name in entries.keys { request(name, loader: loader, inputs: inputs) }
    }

    /// The config for `name`: the current one, the last one while its rebuild runs, or nil (with its first build
    /// started on `loader`) for a name never built.
    ///
    /// - Parameters:
    ///   - name: The theme name (already checked to make one config line).
    ///   - loader: Where a build runs.
    ///   - inputs: The build's snapshot, taken now on the main actor.
    func config(named name: String, loader: any GhosttyConfigLoading,
                inputs: (String) -> GhosttyConfigInputs) -> GhosttyThemeConfig? {
        entries[name, default: Entry()].asked = true
        request(name, loader: loader, inputs: inputs)
        return entries[name]?.config
    }

    /// Starts `name`'s build for the current generation, unless it is built or building for it.
    private func request(_ name: String, loader: any GhosttyConfigLoading, inputs: (String) -> GhosttyConfigInputs) {
        guard let entry = entries[name], entry.builtEpoch != epoch, entry.requestedEpoch != epoch else { return }
        let (asked, snapshot) = (epoch, inputs(name))
        entries[name]?.requestedEpoch = asked
        loader.load({ snapshot.buildConfig() }) { [weak self] built in
            guard let self else {
                built?.free()
                return
            }
            self.land(built, name: name, asked: asked)
        }
    }

    /// Swaps in a landed build of the current generation (the replaced config frees when its last holder lets it
    /// go) and runs the handlers once; frees a superseded one. A failed build keeps the last config.
    private func land(_ built: GhosttyBuiltConfig?, name: String, asked: Int) {
        guard asked == epoch, var entry = entries[name], entry.requestedEpoch == asked else {
            built?.free()
            return
        }
        entry.requestedEpoch = nil
        entry.builtEpoch = asked
        guard let built, let config = built.config else {
            entries[name] = entry
            return
        }
        // SAFETY: the landed build's live config, handed over to the theme config, which frees it
        // once (GhosttyThemeConfig's `config`); nothing frees `built` after this.
        entry.config = unsafe GhosttyThemeConfig(config: config, themeName: name,
                                                 colors: GhosttyRuntime.themeColors(of: config, backgroundOpacity: built.opacity))
        entry.asked = false
        entries[name] = entry
        for handler in handlers { handler() }
    }
}
