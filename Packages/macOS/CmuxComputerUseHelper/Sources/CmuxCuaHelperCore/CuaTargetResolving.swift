// SPDX-License-Identifier: GPL-3.0-or-later

/// Side-effect-free app lookups, injectable without AppKit or a running driver.
protocol CuaTargetResolving: Sendable {
    func app(forPID pid: Int32) async -> CuaTargetIdentity?
    func app(forWindowID id: UInt32) async -> CuaTargetIdentity?
    func app(named name: String) async -> CuaTargetIdentity?
    func app(forBundleID id: String) async -> CuaTargetIdentity?
}
