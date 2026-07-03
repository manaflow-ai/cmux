import AppKit

@MainActor
final class ZeroWindowNumberWindow: NSWindow {
    override var windowNumber: Int { 0 }
}
