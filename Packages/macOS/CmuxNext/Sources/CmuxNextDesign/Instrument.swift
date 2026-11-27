/// Instrument, cmux's component library, on the Swift side: the names the web kit
/// (`webviews/src/kit/index.ts`) exports, mapped to the native views that already draw them.
///
/// Every name here is a `typealias` of a type this module already has, so using one draws exactly
/// what the type draws today; nothing new is drawn and no call site has to move. Version 0.1.0 is the
/// look the app draws today, the same version as the web kit's `INSTRUMENT_VERSION`. The table of web
/// names, Swift types and files, and the names that have no Swift counterpart yet, is
/// `docs/cmux-next/instrument-swift.md`.
///
/// ```swift
/// let card = Instrument.Panel()
/// let row = Instrument.Row(leading: nil, title: title)
/// ```
public struct Instrument {
    /// Makes the library's front door; it holds no state.
    public init() {}

    /// The library's version: `0.1.0` is the look the app draws today, as on the web
    /// (`webviews/src/kit/version.ts`). A patch adds or re-exports names with no pixel moved;
    /// a minor moves a drawn default.
    nonisolated public static let version = "0.1.0"

    /// The library's version, read from an instance (``Instrument/version``).
    public var version: String { Self.version }

    /// The web kit's `Button`, AppKit side: the base of every chrome button (``ClickableButton``).
    public typealias Button = ClickableButton

    /// The web kit's `Button` press, SwiftUI side: the one pressed look (``CmuxPressFillButtonStyle``).
    public typealias ButtonStyle = CmuxPressFillButtonStyle

    /// The web kit's `Row`: leading column, title, optional subtitle, trailing view (``PopupRowView``).
    public typealias Row = PopupRowView

    /// The web kit's `Panel` (`Surface`): the card surface the sidebar's cards draw (``CardSurfaceView``).
    public typealias Panel = CardSurfaceView

    /// The web kit's `Glass`: one glass panel on every macOS version (``GlassPanelView``).
    public typealias Glass = GlassPanelView

    /// The web kit's `GlassLevel`: `chrome`, `popover`, `menu`, `chip` (``CmuxNextDesign/GlassLevel``).
    public typealias GlassLevel = CmuxNextDesign.GlassLevel

    /// The web kit's `GlassMenu`: a menu on cmux's own glass (``CmuxNextDesign/GlassMenu``).
    public typealias GlassMenu = CmuxNextDesign.GlassMenu

    /// The web kit's `Tooltip` and `TooltipProvider`: the app's one tooltip, hover delay and warm
    /// group included (``TooltipPresenter``).
    public typealias Tooltip = TooltipPresenter

    /// The web kit's motion tokens: the one source of animation timing (``CmuxNextDesign/Motion``).
    public typealias Motion = CmuxNextDesign.Motion
}
