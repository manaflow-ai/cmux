public import CmuxNextDesign
import CoreGraphics
import Foundation

/// Where the screen-share viewer shows the stream's quality (Debug Settings `macScreen.qualityReadout`). D10
/// (screen-share-under-100ms) streams at the link's rate with near-lossless text; the view says so with the
/// host's own numbers (cmux.rd/1 `stats`: rate, loss, encode time). Every variant reads the same
/// ``MacScreenQualityReadout/rows(_:frameSize:path:)``; they differ only in where the numbers go.
public nonisolated enum MacScreenQualityReadout: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// R1: the toolbar's stats line leads with the rate (`Direct · 148 Mbps · 120/120 fps · 3 ms`).
    case inline
    /// R2: the Quality button shows the rate (`148 Mbps`), its menu opens on the full readout, and its tint
    /// turns to attention when the stream strains.
    case chip
    /// R3: a glass panel in the picture's bottom-left corner, one number per line, shown with Show Stats.
    case hud

    public var tunableTitle: String {
        switch self {
        case .inline: "Inline (default): the rate leads the toolbar's stats line"
        case .chip: "Quality chip: the rate on the Quality button, the readout in its menu"
        case .hud: "Stats panel: the numbers in a corner of the picture"
        }
    }
}

extension MacScreenQualityReadout {
    /// A rate in the unit people read: `148 Mbps`, `4.2 Mbps`, `850 kbps`.
    static func rateText(kbps: Double) -> String {
        guard kbps.isFinite, kbps > 0 else { return "0 kbps" }
        if kbps >= 10_000 { return String(format: "%.0f Mbps", kbps / 1000) }
        if kbps >= 1000 { return String(format: "%.1f Mbps", kbps / 1000) }
        return String(format: "%.0f kbps", kbps)
    }

    /// The word for the profile the host measured: `Ultra` for an ultra session, nil otherwise. Standard is the
    /// ordinary case and a host too old to say gets no word, so the rate stands alone.
    static func profileWord(_ profile: String?) -> String? {
        profile == "ultra" ? L.t("macScreen.readout.ultra", "Ultra") : nil
    }

    /// The rate with the profile word when the host named one: `Ultra · 148 Mbps`, else `148 Mbps`.
    static func rateText(kbps: Double, profile: String?) -> String {
        let rate = rateText(kbps: kbps)
        return profileWord(profile).map { "\($0) · \(rate)" } ?? rate
    }

    /// The stream is straining: the host loses more than 5% or the picture runs under half its rate.
    static func isStrained(_ stats: MacScreenSession.LiveStats) -> Bool {
        if let loss = stats.lossPercent, loss > 5 { return true }
        if let target = stats.targetFps, target > 0, stats.fps > 0, stats.fps < Double(target) / 2 { return true }
        return false
    }

    /// The rate row's label: the row a strained stream marks in the attention ink, wherever it sits.
    static var rateLabel: String { L.t("macScreen.readout.rate", "Rate") }

    /// The full readout, one row per number, in reading order. A number the host has not sent is left out.
    static func rows(_ stats: MacScreenSession.LiveStats, frameSize: CGSize, path: String) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if path != "-" { rows.append((L.t("macScreen.readout.path", "Route"), path)) }
        if let profile = stats.encodeProfile {
            let word = profileWord(profile) ?? L.t("macScreen.readout.standard", "Standard")
            rows.append((L.t("macScreen.readout.mode", "Mode"), word))
        }
        if let kbps = stats.hostKbps { rows.append((rateLabel, rateText(kbps: kbps))) }
        let measured = stats.fps.isFinite ? Int(stats.fps.rounded()) : 0
        rows.append((L.t("macScreen.readout.fps", "Frames"),
                     stats.targetFps.map { "\(measured)/\($0) fps" } ?? "\(measured) fps"))
        if let rtt = stats.latencyMs { rows.append((L.t("macScreen.readout.rtt", "Round trip"), String(format: "%.0f ms", rtt))) }
        if let loss = stats.lossPercent { rows.append((L.t("macScreen.readout.loss", "Loss"), String(format: "%.1f%%", loss))) }
        if let encode = stats.encodeMsP50 {
            rows.append((L.t("macScreen.readout.encode", "Encode"), String(format: "%.1f ms", encode)))
        }
        if stats.encoding != "-" { rows.append((L.t("macScreen.readout.codec", "Codec"), stats.encoding)) }
        if frameSize.width >= 1 {
            rows.append((L.t("macScreen.readout.size", "Size"), "\(Int(frameSize.width))×\(Int(frameSize.height))"))
        }
        return rows
    }
}
