import CmuxSettingsUI
import CoreWLAN
import IOKit.ps
import SwiftUI

// SleepyTheme / SleepyMascot / SleepyGlow / SleepyModeConfig / the settings
// store live in CmuxSettingsUI so the Preferences section can bind to them.

// MARK: - Palettes

enum SleepyPalette {
    static func colors(for config: SleepyModeConfig) -> [Character: Color] {
        switch config.theme {
        case .custom:
            let face = Color(sleepyHex: config.customFace)
            let cap = Color(sleepyHex: config.customCap)
            let logo = Color(sleepyHex: config.customLogo)
            return [
                "O": face,
                "o": face.sleepyDarkened(0.22),
                "P": cap,
                "p": cap.sleepyDarkened(0.32),
                "W": .white,
                "B": Color(sleepyHex: config.customBlush),
                "H": logo.sleepyLightened(0.30),
                "C": logo,
                "c": logo.sleepyDarkened(0.30),
                "Y": Color(red: 1.0, green: 0.93, blue: 0.70),
            ]
        case .cmux:
            return base(
                face: Color(red: 0.88, green: 0.93, blue: 1.0),
                faceShade: Color(red: 0.69, green: 0.77, blue: 0.93),
                cap: Color(red: 0.36, green: 0.84, blue: 1.0),
                capShade: Color(red: 0.18, green: 0.55, blue: 0.86)
            )
        case .blossom:
            return base(
                face: Color(red: 1.0, green: 0.94, blue: 0.96),
                faceShade: Color(red: 0.95, green: 0.78, blue: 0.85),
                cap: Color(red: 1.0, green: 0.55, blue: 0.72),
                capShade: Color(red: 0.85, green: 0.34, blue: 0.55)
            )
        case .mint:
            return base(
                face: Color(red: 0.90, green: 1.0, blue: 0.95),
                faceShade: Color(red: 0.70, green: 0.90, blue: 0.80),
                cap: Color(red: 0.35, green: 0.86, blue: 0.66),
                capShade: Color(red: 0.18, green: 0.62, blue: 0.46)
            )
        case .mono:
            return base(
                face: Color(white: 0.92),
                faceShade: Color(white: 0.66),
                cap: Color(white: 0.55),
                capShade: Color(white: 0.36)
            )
        }
    }

    /// Shared accents (blush, pom-pom, moon, and the always-cyan cmux logo).
    private static func base(face: Color, faceShade: Color, cap: Color, capShade: Color) -> [Character: Color] {
        [
            "O": face,
            "o": faceShade,
            "P": cap,
            "p": capShade,
            "W": .white,
            "B": Color(red: 1.0, green: 0.60, blue: 0.71),
            "H": Color(red: 0.74, green: 0.96, blue: 1.0),   // cmux logo highlight
            "C": Color(red: 0.42, green: 0.87, blue: 1.0),
            "c": Color(red: 0.16, green: 0.52, blue: 0.93),
            "Y": Color(red: 1.0, green: 0.93, blue: 0.70),
        ]
    }

    static func ink(for config: SleepyModeConfig) -> Color {
        switch config.theme {
        case .custom: return Color(sleepyHex: config.customInk)
        case .mono: return Color(white: 0.18)
        default: return Color(red: 0.20, green: 0.24, blue: 0.42)
        }
    }

    static func glowColors(for config: SleepyModeConfig) -> [Color] {
        switch config.glow {
        case .custom:
            let bg = Color(sleepyHex: config.customBackground)
            return [bg, bg]
        case .black:
            return [.black, .black]
        case .midnight:
            return [Color(red: 0.06, green: 0.07, blue: 0.14), Color(red: 0.01, green: 0.01, blue: 0.03)]
        case .cmux:
            return [Color(red: 0.08, green: 0.16, blue: 0.28), Color(red: 0.01, green: 0.02, blue: 0.06)]
        case .aurora:
            return [Color(red: 0.07, green: 0.20, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.10)]
        case .sunset:
            return [Color(red: 0.22, green: 0.10, blue: 0.16), Color(red: 0.05, green: 0.02, blue: 0.06)]
        case .ocean:
            return [Color(red: 0.05, green: 0.12, blue: 0.22), Color(red: 0.01, green: 0.02, blue: 0.05)]
        }
    }
}

// MARK: - Pixel art assets

enum SleepyArt {
    /// Shared face anchors for the grid mascots (cmux/cat/ghost).
    static let closedEyes: [(Int, Int)] = [(4, 7), (7, 7), (5, 8), (6, 8), (8, 7), (11, 7), (9, 8), (10, 8)]
    static let openEyes: [(Int, Int)] = [(5, 7), (6, 7), (5, 8), (6, 8), (9, 7), (10, 7), (9, 8), (10, 8)]
    static let mouthTop: [(Int, Int)] = [(7, 10), (8, 10)]
    static let mouthOpen: [(Int, Int)] = [(7, 11), (8, 11)]

    static func mascotRows(_ mascot: SleepyMascot) -> [String] {
        switch mascot {
        case .cmux: return cmuxMascot
        case .cat: return catMascot
        case .ghost: return ghostMascot
        case .logoFace: return []
        }
    }

    /// Head + droopy nightcap (16x16).
    static let cmuxMascot: [String] = [
        "............WW..",
        "..........PPWW..",
        "........PPPPP...",
        "......PPPPPPP...",
        "....PPPPPPPPP...",
        "...PPPPPPPPPP...",
        "...pOOOOOOOOp...",
        "..OOOOOOOOOOOO..",
        "..OBBOOOOOOBBO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "...OOOOOOOOOo...",
        "...OOOOOOOOoo...",
        "....OOOOOOoo....",
        ".....OOOOoo.....",
        "................",
    ]

    /// Cat: round head with pointy ears and whiskers (16x16).
    static let catMascot: [String] = [
        "................",
        "....O......O....",
        "...OBO....OBO...",
        "..OOOO....OOOO..",
        "..OOOOO..OOOOO..",
        "...OOOOOOOOOO...",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OBBOOOOOOBBO..",
        "o.OOOOOOOOOOOO.o",
        "o.OOOOOOOOOOOO.o",
        "...OOOOOOOOOO...",
        "...OOOOOOOOOO...",
        "....OOOOOOOO....",
        ".....OOOOOO.....",
        "................",
    ]

    /// Ghost: domed top, wavy feet (16x16).
    static let ghostMascot: [String] = [
        "................",
        "................",
        "................",
        "....OOOOOOOO....",
        "...OOOOOOOOOO...",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OBBOOOOOOBBO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOOOOOOOOOOO..",
        "..OOO.OOO.OOO...",
    ]

    /// Detailed beveled right-pointing cmux chevron (11x15): highlight (H) on the
    /// leading edge, main (C) body, shadow (c) trailing edge. Doubles as the left
    /// eye of the logoFace mascot.
    static let cmuxLogo: [String] = [
        "HCCc.......",
        ".HCCc......",
        "..HCCc.....",
        "...HCCc....",
        "....HCCc...",
        ".....HCCc..",
        "......HCCc.",
        ".......HCCc",
        "......HCCc.",
        ".....HCCc..",
        "....HCCc...",
        "...HCCc....",
        "..HCCc.....",
        ".HCCc......",
        "HCCc.......",
    ]

    static let moon: [String] = [
        ".YY..",
        "YYY..",
        "YY...",
        "YYY..",
        ".YY..",
    ]

    static let zGlyph: [String] = [
        "ZZZZZ",
        "...Z.",
        "..Z..",
        ".Z...",
        "ZZZZZ",
    ]

    // 3x5 pixel font (digits, colon, slash).
    static let font: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", "###", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", "..#", "..#", "..#"],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
        ":": [".", "#", ".", "#", "."],
        "/": ["..#", "..#", ".#.", "#..", "#.."],
    ]

    /// Precomputed glyph rows for the clock, so the 30fps render path never
    /// allocates strings (no per-frame `String(format:)`).
    static let digitGlyphs: [[String]] = (0...9).map { font[Character(String($0))] ?? [] }
    static let colonGlyph: [String] = font[":"] ?? []
    static let slashGlyph: [String] = font["/"] ?? []

    struct Star { let x: Double; let y: Double; let big: Bool; let speed: Double; let phase: Double }

    static let stars: [Star] = [
        Star(x: 0.22, y: 0.34, big: true, speed: 1.7, phase: 0.0),
        Star(x: 0.80, y: 0.24, big: false, speed: 2.1, phase: 1.2),
        Star(x: 0.66, y: 0.40, big: false, speed: 2.6, phase: 0.5),
        Star(x: 0.88, y: 0.52, big: false, speed: 1.9, phase: 2.0),
        Star(x: 0.12, y: 0.56, big: false, speed: 2.3, phase: 3.1),
        Star(x: 0.30, y: 0.70, big: true, speed: 1.5, phase: 0.8),
        Star(x: 0.82, y: 0.72, big: false, speed: 2.8, phase: 1.7),
        Star(x: 0.52, y: 0.62, big: false, speed: 2.2, phase: 2.6),
    ]
}

// MARK: - System status (battery + wifi)

struct SleepyStatusSample: Sendable {
    var batteryLevel: Double?   // 0...1, nil if no battery (desktop)
    var charging: Bool
    var wifiBars: Int?          // 0...4, nil if unknown/unavailable
}

/// Samples battery + wifi at most every few seconds (reads are cheap but not
/// worth doing every frame). `@MainActor`-isolated: sampled from the renderer's
/// TimelineView body on the main actor, so the cache has enforced isolation
/// rather than `nonisolated(unsafe)` + convention.
@MainActor
final class SleepyStatusProvider {
    static let shared = SleepyStatusProvider()
    private var cached = SleepyStatusSample(batteryLevel: nil, charging: false, wifiBars: nil)
    private var lastSample: Double = -100
    private let interval: Double = 4

    func sample(at time: Double) -> SleepyStatusSample {
        if time - lastSample >= interval {
            lastSample = time
            cached = SleepyStatusSample(
                batteryLevel: Self.readBattery()?.level,
                charging: Self.readBattery()?.charging ?? false,
                wifiBars: Self.readWifiBars()
            )
        }
        return cached
    }

    private static func readBattery() -> (level: Double, charging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = desc[kIOPSMaxCapacityKey as String] as? Int, maximum > 0
            else { continue }
            let charging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            return (min(1, max(0, Double(current) / Double(maximum))), charging)
        }
        return nil
    }

    private static func readWifiBars() -> Int? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        switch rssi {
        case ..<(-80): return 1
        case ..<(-70): return 2
        case ..<(-60): return 3
        default: return 4
        }
    }
}
