public import AppKit
import CmuxNextDesign

/// What the location chip says now, as values: the words, the tone, the place's glyph and the
/// help. ``ChiefTeleportChip`` draws it; a web page (the Home Messages page's header chip,
/// webviews/src/pages/home-messages/transcript/ChiefPlaceChip.tsx) gets it as JSON.
public nonisolated struct ChiefTeleportChipFace: Sendable, Equatable, Encodable {
    /// `here`, `away`, `running` or `failed`.
    public var tone: String
    public var text: String
    /// `thisMac`, `cloud`, `host`, `moving`, `rollingBack` or `failed`.
    public var glyph: String
    /// The chip's accessibility label ("Chief location: …").
    public var label: String
    public var help: String

    /// The SF Symbol the chip draws for ``glyph``.
    var symbol: String {
        switch glyph {
        case "thisMac": "laptopcomputer"
        case "cloud": "cloud"
        case "host": "macmini"
        case "rollingBack": "arrow.uturn.backward"
        case "failed": "exclamationmark.triangle"
        default: "arrow.triangle.2.circlepath"
        }
    }
}

extension ChiefTeleportModel {
    /// The chip's face now. `saysAway`: a Chief on another host reads "Chief is on <host>" (Home's
    /// header, which cannot open the Chief there); off, the host's name alone (the Chief card).
    public func chipFace(saysAway: Bool) -> ChiefTeleportChipFace {
        let phase = shownPhase
        let place = ChiefTeleportChip.placeTitle(location, current: menu().currentTitle)
        let (tone, text, glyph): (String, String, String)
        switch phase {
        case .checking, .moving, .verifying, .rollingBack:
            (tone, text, glyph) = ("running", ChiefTeleportMenuBuilder.statusLine(phase) ?? place, phase == .rollingBack ? "rollingBack" : "moving")
        case .failed:
            (tone, text, glyph) = ("failed", ChiefTeleportMenuBuilder.statusLine(phase) ?? place, "failed")
        case .idle, .done, .rolledBack:
            let words = if saysAway, case .host = location {
                ChiefTeleportStrings.awayOn(place)
            } else if location == .thisMac, marks.fork != nil {
                ChiefTeleportStrings.withFork(place)
            } else {
                place
            }
            let mark = switch location {
            case .thisMac: "thisMac"
            case .cloud: "cloud"
            case .host: "host"
            }
            (tone, text, glyph) = (location == .thisMac ? "here" : "away", words, mark)
        }
        return ChiefTeleportChipFace(tone: tone, text: text, glyph: glyph, label: ChiefTeleportStrings.label(text), help: ChiefTeleportStrings.help)
    }

    /// Pops the Teleport menu up under `rect` of `view` (a page's chip, in the view's coordinates).
    public func openMenu(under rect: CGRect, in view: NSView) {
        let builder = ChiefTeleportMenuBuilder(model: self)  // the items' target; the pop-up tracks synchronously
        let menu = builder.makeMenu()
        let y = view.isFlipped ? rect.maxY + CmuxPopoverAnchor.defaultGap : rect.minY - CmuxPopoverAnchor.defaultGap
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: y), in: view)
        withExtendedLifetime(builder) {}
    }
}
