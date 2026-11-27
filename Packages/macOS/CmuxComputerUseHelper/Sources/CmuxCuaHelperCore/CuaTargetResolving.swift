// SPDX-License-Identifier: GPL-3.0-or-later

/// Side-effect-free app lookups, injectable without AppKit or a running driver.
protocol CuaTargetResolving: Sendable {
    func app(forPID pid: Int32) async -> CuaTargetIdentity?
    func app(forWindowID id: UInt32) async -> CuaTargetIdentity?
    func app(named name: String) async -> CuaTargetIdentity?
    func app(forBundleID id: String) async -> CuaTargetIdentity?
    /// Whether window `id` keeps itself out of screen capture and screen sharing
    /// (`NSWindow.sharingType = .none`, CGWindowList's `kCGWindowSharingState` of none):
    /// a consent or secret prompt only the person answers. False for a window not found.
    func isCaptureExcluded(windowID id: UInt32) async -> Bool
}
