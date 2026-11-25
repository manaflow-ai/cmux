// CmuxNextDesignTokens for the Linux settings exporter (scripts/cmux-next/regenerate-settings-exports-linux.sh): its
// portable files are linked in as they are; this stands in for what reads the Rust motion FFI (Motion/SpringValue.swift),
// which the exporter does not link. Nothing here runs: the exports read the settings' declarations only.
#if !canImport(AppKit)
public import Foundation

nonisolated extension SpringParameters {
    /// The Mac simulates the spring through the FFI; no export reads it.
    public var perceivedDuration: Double { 0 }
}
#endif
