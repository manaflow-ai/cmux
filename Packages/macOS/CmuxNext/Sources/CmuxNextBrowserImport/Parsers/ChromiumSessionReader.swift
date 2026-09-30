public import Foundation

/// Reads the open tabs of a Chromium session file (`Sessions/Session_<n>`,
/// or `Current Session` on older versions). The file is an "SNSS" command
/// log: after an 8-byte header ("SNSS", int32 version), each command is a
/// uint16 size, a uint8 id and `size - 1` payload bytes. Replaying the tab
/// and window commands gives the tabs that were open, each at its selected
/// navigation. Encrypted session files (versions 2 and 4) are skipped.
public enum ChromiumSessionReader {
    // session_service_commands.cc command ids.
    static let setTabWindow: UInt8 = 0
    static let setTabIndexInWindow: UInt8 = 2
    static let updateTabNavigation: UInt8 = 6
    static let setSelectedNavigationIndex: UInt8 = 7
    static let setPinnedState: UInt8 = 12
    static let tabClosed: UInt8 = 16
    static let windowClosed: UInt8 = 17

    /// The newest `Session_*` file in a profile's `Sessions` folder.
    public static func latestSessionFile(in sessions: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        return names.filter { $0.hasPrefix("Session_") }
            .max { (Int64($0.dropFirst(8)) ?? 0) < (Int64($1.dropFirst(8)) ?? 0) }
            .map { sessions.appending(path: $0) }
    }

    public static func sessionFile(profile: URL) -> URL? {
        if let latest = latestSessionFile(in: profile.appending(path: "Sessions")) { return latest }
        let legacy = profile.appending(path: "Current Session")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    private struct Tab {
        var window: Int32 = 0
        var index: Int32 = 0
        var pinned = false
        var selected: Int32?
        var navigations: [Int32: (url: String, title: String)] = [:]
    }

    public static func parse(_ data: Data) -> [ImportedTab] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("SNSS".utf8) else { return [] }
        let version = PickleReader.uint32(bytes, at: 4)
        guard version == 1 || version == 3 else { return [] }
        var tabs: [Int32: Tab] = [:]
        var closedWindows: Set<Int32> = []
        var offset = 8
        while offset + 3 <= bytes.count {
            let size = Int(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            guard size >= 1, offset + 2 + size <= bytes.count else { break }
            let id = bytes[offset + 2]
            let payload = Data(bytes[(offset + 3)..<(offset + 2 + size)])
            offset += 2 + size
            apply(id, payload, to: &tabs, closedWindows: &closedWindows)
        }
        let open = tabs.values.filter { !closedWindows.contains($0.window) }
            .sorted { ($0.window, $0.index) < ($1.window, $1.index) }
        let windows = Array(Set(open.map(\.window))).sorted()
        return open.compactMap { tab in
            let index = tab.selected ?? tab.navigations.keys.max()
            guard let index, let navigation = tab.navigations[index], let url = ImportableURL.parse(navigation.url) else { return nil }
            return ImportedTab(url: url, title: navigation.title.isEmpty ? nil : navigation.title,
                               window: windows.firstIndex(of: tab.window) ?? 0, pinned: tab.pinned)
        }
    }

    private static func apply(_ id: UInt8, _ payload: Data, to tabs: inout [Int32: Tab], closedWindows: inout Set<Int32>) {
        switch id {
        case updateTabNavigation:
            guard var pickle = PickleReader(payload), let tab = pickle.int32(), let index = pickle.int32(),
                  let url = pickle.string(), let title = pickle.string16() else { return }
            tabs[tab, default: Tab()].navigations[index] = (url, title)
        case setSelectedNavigationIndex:
            var raw = PickleReader(raw: payload)
            guard let tab = raw.int32(), let index = raw.int32() else { return }
            tabs[tab, default: Tab()].selected = index
        case setTabWindow:
            var raw = PickleReader(raw: payload)
            guard let window = raw.int32(), let tab = raw.int32() else { return }
            tabs[tab, default: Tab()].window = window
        case setTabIndexInWindow:
            var raw = PickleReader(raw: payload)
            guard let tab = raw.int32(), let index = raw.int32() else { return }
            tabs[tab, default: Tab()].index = index
        case setPinnedState:
            var raw = PickleReader(raw: payload)
            guard let tab = raw.int32(), let pinned = raw.int32() else { return }
            tabs[tab, default: Tab()].pinned = pinned & 0xFF != 0
        case tabClosed:
            var raw = PickleReader(raw: payload)
            guard let tab = raw.int32() else { return }
            tabs[tab] = nil
        case windowClosed:
            var raw = PickleReader(raw: payload)
            guard let window = raw.int32() else { return }
            closedWindows.insert(window)
        default:
            return
        }
    }
}
