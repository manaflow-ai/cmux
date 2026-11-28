/// The daemon's answer to `_acpmux/web_modes` (acpmux `web_modes.rs` is the one source of truth;
/// the host keeps no copy of these lists).
public nonisolated struct AcpmuxWebModes: Equatable, Sendable {
    /// Fields that could set a mode or a sandbox (`MODE_FIELDS`): refused in a page frame's params
    /// and `_meta.acpmux` on every method except session/set_mode and session/set_config_option.
    public var modeFields: Set<String>
    /// Config options any value of which keeps a session asking (`FREE_CONFIG_IDS`).
    public var freeConfigIds: Set<String>
    /// Whether the asked value keeps the session asking; nil when the daemon did not say (no
    /// session, no string value).
    public var asks: Bool?

    public init(modeFields: Set<String>, freeConfigIds: Set<String>, asks: Bool?) {
        self.modeFields = modeFields
        self.freeConfigIds = freeConfigIds
        self.asks = asks
    }
}
