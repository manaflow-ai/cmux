public import Foundation
import CmuxNextCompat

/// Reads the open tabs of a Chromium session file (`Sessions/Session_<n>`,
/// or `Current Session` on older versions). The file is an "SNSS" command
/// log: after an 8-byte header ("SNSS", int32 version), each command is a
/// uint16 size, a uint8 id and `size - 1` payload bytes. Replaying the tab
/// and window commands gives the tabs that were open, each at its selected
/// navigation. Encrypted session files (versions 2 and 4) are skipped.
public struct ChromiumSessionReader {

    /// Creates a reader of Chromium sessions.
    public init() {}

    // session_service_commands.cc command ids.
    let setTabWindow: UInt8 = 0
    let setTabIndexInWindow: UInt8 = 2
    let updateTabNavigation: UInt8 = 6
    let setSelectedNavigationIndex: UInt8 = 7
    let setPinnedState: UInt8 = 12
    let tabClosed: UInt8 = 16
    let windowClosed: UInt8 = 17

    /// The newest `Session_*` file in a profile's `Sessions` folder.
    public func latestSessionFile(in sessions: URL) -> URL? {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: sessions.path)) ?? []
        return names.filter { $0.hasPrefix("Session_") }
            .max { (Int64($0.dropFirst(8)) ?? 0) < (Int64($1.dropFirst(8)) ?? 0) }
            .map { sessions.appending(path: $0) }
    }

    public func sessionFile(profile: URL) -> URL? {
        if let latest = latestSessionFile(in: profile.appending(path: "Sessions")) { return latest }
        let legacy = profile.appending(path: "Current Session")
        return FileManager.checked.fileExists(atPath: legacy.path) ? legacy : nil
    }

    private struct Tab {
        var window: Int32 = 0
        var index: Int32 = 0
        var pinned = false
        var selected: Int32?
        var navigations: [Int32: (url: String, title: String)] = [:]
    }

    /// The open tabs; a tab with no page to show or an address that is not importable is counted.
    public func parse(_ data: Data) -> ImportRead<ImportedTab> {
        let bytes = [UInt8](data)
        guard bytes.starts(with: "SNSS".utf8), let version = PickleReader.uint32(bytes.dropFirst(4)),
              version == 1 || version == 3 else { return ImportRead() }
        var tabs: [Int32: Tab] = [:]
        var closedWindows: Set<Int32> = []
        // Each command is taken from the front of what is left: a uint16 size, then `size` bytes (the id and payload).
        var rest = bytes.dropFirst(8)
        while rest.count >= 3 { // wakeup-allow: bounded each pass drops at least 3 bytes
            let size = rest.prefix(2).littleEndian(as: UInt16.self).widened
            let command = rest.dropFirst(2).prefix(size)
            guard size >= 1, command.count == size, let id = command.first else { break }
            rest = rest.dropFirst(2 + size)
            apply(id, Data(command.dropFirst()), to: &tabs, closedWindows: &closedWindows)
        }
        let open = tabs.values.filter { !closedWindows.contains($0.window) }
            .sorted { ($0.window, $0.index) < ($1.window, $1.index) }
        let windows = Array(Set(open.map(\.window))).sorted()
        var read = ImportRead<ImportedTab>()
        for tab in open {
            guard let index = tab.selected ?? tab.navigations.keys.max(), let navigation = tab.navigations[index] else {
                read.skipped.unsupported += 1
                continue
            }
            guard let url = ImportableURL.parse(navigation.url) else {
                read.skipped.notImportable += 1
                continue
            }
            read.items.append(ImportedTab(url: url, title: navigation.title.isEmpty ? nil : navigation.title,
                                          window: windows.firstIndex(of: tab.window) ?? 0, pinned: tab.pinned))
        }
        return read
    }

    private func apply(_ id: UInt8, _ payload: Data, to tabs: inout [Int32: Tab], closedWindows: inout Set<Int32>) {
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
