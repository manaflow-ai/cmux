// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@preconcurrency import CoreGraphics
import Foundation

struct RunningApp: Sendable, Equatable {
    var pid: pid_t
    var name: String
    var bundleID: String?
    var path: String?
    var isActive: Bool
    var isHidden: Bool
}

struct WindowInfo: Sendable, Equatable {
    var id: CGWindowID
    var pid: pid_t
    var title: String
    var frame: CGRect
    var layer: Int
    var onScreen: Bool
}

/// Finds apps and their windows. Apps are addressed the way agents name
/// them (display name, bundle id or path, case-insensitive), as Codex
/// Computer Use does, so a call needs no pid lookup first.
struct AppDirectory: Sendable {
    func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
            return RunningApp(pid: app.processIdentifier, name: name, bundleID: app.bundleIdentifier,
                              path: app.bundleURL?.path, isActive: app.isActive, isHidden: app.isHidden)
        }
    }

    enum LookupError: Error, CustomStringConvertible {
        case notRunning(String)
        case ambiguous(String, [String])

        var description: String {
            switch self {
            case .notRunning(let app): "no running app matches \"\(app)\" (call list_apps for names)"
            case .ambiguous(let app, let names): "\"\(app)\" matches several apps: \(names.joined(separator: ", "))"
            }
        }
    }

    func resolve(_ query: String) throws -> RunningApp {
        let apps = runningApps()
        if let pid = pid_t(query), let app = apps.first(where: { $0.pid == pid }) { return app }
        let lowered = query.lowercased()
        let exact = apps.filter {
            $0.name.lowercased() == lowered || $0.bundleID?.lowercased() == lowered
                || $0.path.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                == lowered.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return exact.first(where: \.isActive) ?? exact[0] }
        let partial = apps.filter { $0.name.lowercased().contains(lowered) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 { throw LookupError.ambiguous(query, partial.map(\.name)) }
        throw LookupError.notRunning(query)
    }

    /// One window by id, without listing every window on the system
    /// (`CGWindowListCreateDescriptionFromArray` asks only for this id).
    func window(id: CGWindowID, pid: pid_t) -> WindowInfo? {
        // A CFArray of raw window ids (not boxed Swift values): the call reads
        // each element as a CGWindowID.
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let ids = values.withUnsafeMutableBufferPointer({ CFArrayCreate(nil, $0.baseAddress, 1, nil) }),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let entry = list.first else { return nil }
        return Self.info(entry, pid: pid)
    }

    static func info(_ entry: [String: Any], pid: pid_t) -> WindowInfo? {
        guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 1, frame.height > 1
        else { return nil }
        return WindowInfo(id: id, pid: pid, title: entry[kCGWindowName as String] as? String ?? "",
                          frame: frame, layer: layer,
                          onScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    /// Layer-0 windows of `pid`, front to back.
    func windows(pid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { Self.info($0, pid: pid) }
    }
}
