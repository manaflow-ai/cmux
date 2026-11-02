// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation

/// Resolves WindowServer owners and installed app bundles without activating them.
actor MacCuaTargetResolver: CuaTargetResolving {
    func app(forPID pid: Int32) async -> CuaTargetIdentity? {
        // NSRunningApplication documents atomic, thread-safe property access.
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier else { return nil }
        return CuaTargetIdentity(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    func app(forWindowID id: UInt32) async -> CuaTargetIdentity? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        return await app(forPID: pid)
    }

    func app(named name: String) async -> CuaTargetIdentity? {
        // Match the pinned driver's locate_by_name search order. Read bundles
        // on this actor, never on the main actor and never by launching an app.
        let appName = name.hasSuffix(".app") ? name : name + ".app"
        let home = NSHomeDirectory()
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities", home + "/Applications", home + "/Applications/Chrome Apps.localized"]
        let paths = name.hasPrefix("/") ? [name] : roots.map { $0 + "/" + appName }
        for path in paths {
            if let app = identity(at: URL(fileURLWithPath: path)) { return app }
        }
        // The driver's name parameter also accepts a bundle identifier.
        return await app(forBundleID: name)
    }

    func app(forBundleID id: String) async -> CuaTargetIdentity? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return identity(at: url)
    }

    private func identity(at url: URL) -> CuaTargetIdentity? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        return CuaTargetIdentity(bundleID: bundleID,
                                 name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                     ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                                     ?? url.deletingPathExtension().lastPathComponent)
    }
}
