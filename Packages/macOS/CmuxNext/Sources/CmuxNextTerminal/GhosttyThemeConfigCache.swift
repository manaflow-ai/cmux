/// The user's config with one theme applied, per theme name (``GhosttyRuntime/themeConfig(named:)``): each one is
/// built once on the config loader, off the main thread, cached when it lands, and dropped on every config change
/// (``dropAll()``), after which a build still in flight lands as stale and is freed.
final class GhosttyThemeConfigCache {
    private var configs: [String: GhosttyThemeConfig] = [:]
    /// The names whose build is in flight, or failed since the last change (asking again does not rebuild it).
    private var loads: Set<String> = []
    /// Bumps on ``dropAll()``.
    private var epoch = 0
    private var handlers: [@MainActor () -> Void] = []

    /// Runs `handler` each time a build lands and is cached.
    func addHandler(_ handler: @escaping @MainActor () -> Void) {
        handlers.append(handler)
    }

    /// Drops every config (the user's config changed).
    func dropAll() {
        configs.removeAll()
        loads.removeAll()
        epoch &+= 1
    }

    /// The cached config for `name`, or nil after starting its build on `loader` (once per name per config).
    ///
    /// - Parameters:
    ///   - name: The theme name (already checked to make one config line).
    ///   - loader: Where the build runs.
    ///   - inputs: The build's snapshot, taken now on the main actor.
    func config(named name: String, loader: any GhosttyConfigLoading,
                inputs: () -> GhosttyConfigInputs) -> GhosttyThemeConfig? {
        if let cached = configs[name] { return cached }
        guard loads.insert(name).inserted else { return nil }
        let (asked, snapshot) = (epoch, inputs())
        loader.load({ snapshot.buildConfig() }) { [weak self] built in
            guard let self, asked == self.epoch else {
                built?.free()
                return
            }
            guard let built, let config = built.config else { return }
            self.loads.remove(name)
            self.configs[name] = GhosttyThemeConfig(config: config, themeName: name,
                                                    colors: GhosttyRuntime.themeColors(of: config, backgroundOpacity: built.opacity))
            for handler in self.handlers { handler() }
        }
        return nil
    }
}
