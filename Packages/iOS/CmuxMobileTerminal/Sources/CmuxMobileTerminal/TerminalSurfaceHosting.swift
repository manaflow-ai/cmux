#if canImport(UIKit)
import CMUXMobileCore
import Foundation

/// The surface behaviors the shell layer drives without knowing the concrete
/// view: output ingestion, focus, and the daemon grid pin/unpin pair.
@MainActor
protocol TerminalSurfaceHosting: AnyObject {
    var currentGridSize: TerminalGridSize { get }
    func processOutput(_ data: Data)
    func focusInput()
    /// Apply the daemon's authoritative rendering grid for modes that cannot
    /// reflow independently on the phone, such as alternate-screen TUIs.
    func applyViewSize(cols: Int, rows: Int)
    /// Return to the phone's natural viewport capacity.
    func useNaturalViewSize()
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? { get set }
    func accessibilityRenderedTextForTesting() -> String?
    #endif
}

extension TerminalSurfaceHosting {
    func focusInput() {}
    func applyViewSize(cols _: Int, rows _: Int) {}
    func useNaturalViewSize() {}
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? {
        get { nil }
        set {}
    }
    func accessibilityRenderedTextForTesting() -> String? { nil }
    #endif
}
#endif
