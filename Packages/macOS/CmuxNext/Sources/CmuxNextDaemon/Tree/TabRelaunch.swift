/// A kept tab to restart a shell in (`end-terminals-keep-layout-v1`, wire
/// `relaunch`): the workspace store's keep-layout record, with the
/// directory the tab's shell was in when Quit's End Sessions, Keep Layout
/// ended it.
public struct TabRelaunch: Sendable, Hashable, Codable {
    public var cwd: String?
    /// Parked (`park-tabs`, `tab-park-v1`): its shell starts when its
    /// workspace is first shown, not when the app connects.
    public var onShow: Bool

    public init(cwd: String?, onShow: Bool = false) {
        self.cwd = cwd
        self.onShow = onShow
    }

    enum CodingKeys: String, CodingKey {
        case cwd
        case onShow = "on_show"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        onShow = try container.decodeIfPresent(Bool.self, forKey: .onShow) ?? false
    }
}
