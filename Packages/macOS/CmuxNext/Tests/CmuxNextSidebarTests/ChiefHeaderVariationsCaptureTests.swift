import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Design exploration for the sidebar's Chief row (Lawrence 2026-11-23: "too much space above/below Chief ...
/// maybe chief with a logo?"). Draws a grid of mock sidebar tops, each a different Chief treatment, into
/// `.build/chief-variations-N.png`. Picture only; it checks nothing but that each sheet drew.
@MainActor struct ChiefHeaderVariationsCaptureTests {
    enum Mark {
        case none
        case symbol(String, Color)
        case badge(String, Color)          // symbol in a filled rounded square
        case circle(String, Color)         // symbol in a filled circle
        case monogram(Color)               // "C" tile
        case dot(Color)
    }

    struct Variant: Identifiable {
        let id = UUID()
        var name: String
        var mark: Mark = .none
        var top: CGFloat = 6
        var bottom: CGFloat = 4
        var weight: Font.Weight = .regular
        var size: CGFloat = 13
        var caps = false
        var subtitle: String? = nil
        var pill = false
        var trailingAvatar = false
    }

    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.25)
    static let mint = Color(red: 0.35, green: 0.85, blue: 0.65)
    static let coral = Color(red: 1.0, green: 0.48, blue: 0.42)
    static let violet = Color(red: 0.70, green: 0.50, blue: 1.0)

    static let sheets: [[Variant]] = [
        // Sheet 1: spacing only, no mark.
        [
            Variant(name: "Loose, like today", top: 14, bottom: 14),
            Variant(name: "Tight 6/4", top: 6, bottom: 4),
            Variant(name: "Tight 4/2", top: 4, bottom: 2),
            Variant(name: "Flush row pitch", top: 0, bottom: 0),
            Variant(name: "Semibold, tight", top: 6, bottom: 4, weight: .semibold),
            Variant(name: "Large title 15", top: 4, bottom: 4, weight: .semibold, size: 15),
            Variant(name: "Small caps label", top: 6, bottom: 2, weight: .semibold, size: 11, caps: true),
            Variant(name: "Pill, tight", top: 4, bottom: 2, pill: true),
            Variant(name: "With status line", top: 4, bottom: 4, weight: .medium, subtitle: "Idle · 3 subagents"),
        ],
        // Sheet 2: SF Symbol marks beside the title.
        [
            Variant(name: "Sparkles", mark: .symbol("sparkles", accent)),
            Variant(name: "Crown", mark: .symbol("crown.fill", gold)),
            Variant(name: "Star", mark: .symbol("star.fill", gold)),
            Variant(name: "Compass", mark: .symbol("safari.fill", mint)),
            Variant(name: "Command", mark: .symbol("command", .white.opacity(0.85))),
            Variant(name: "Wand", mark: .symbol("wand.and.stars", violet)),
            Variant(name: "Bolt", mark: .symbol("bolt.fill", gold)),
            Variant(name: "Brain", mark: .symbol("brain.head.profile", coral)),
            Variant(name: "Flag", mark: .symbol("flag.fill", coral)),
        ],
        // Sheet 3: badge / app-icon style marks.
        [
            Variant(name: "Badge sparkles", mark: .badge("sparkles", accent), weight: .semibold),
            Variant(name: "Badge crown", mark: .badge("crown.fill", gold), weight: .semibold),
            Variant(name: "Badge person.wave", mark: .badge("person.wave.2.fill", mint), weight: .semibold),
            Variant(name: "Circle chevron (cmux)", mark: .circle("chevron.right", accent), weight: .semibold),
            Variant(name: "Circle point.3", mark: .circle("point.3.connected.trianglepath.dotted", violet), weight: .semibold),
            Variant(name: "Circle steering", mark: .circle("steeringwheel", coral), weight: .semibold),
            Variant(name: "Monogram C", mark: .monogram(accent), weight: .semibold),
            Variant(name: "Monogram C gold", mark: .monogram(gold), weight: .semibold),
            Variant(name: "Live dot", mark: .dot(mint), weight: .medium),
        ],
        // Sheet 4: combos.
        [
            Variant(name: "Badge + status", mark: .badge("sparkles", accent), weight: .semibold, subtitle: "Working · 2 subagents"),
            Variant(name: "Crown + caps", mark: .symbol("crown.fill", gold), weight: .semibold, size: 11, caps: true),
            Variant(name: "Monogram + avatar", mark: .monogram(violet), weight: .semibold, trailingAvatar: true),
            Variant(name: "Pill + sparkles", mark: .symbol("sparkles", accent), pill: true),
            Variant(name: "Pill + badge", mark: .badge("crown.fill", gold), weight: .semibold, pill: true),
            Variant(name: "Big badge 15", mark: .badge("sparkles", accent), weight: .bold, size: 15),
            Variant(name: "Hexagon", mark: .symbol("hexagon.fill", mint), weight: .semibold),
            Variant(name: "Seal", mark: .symbol("checkmark.seal.fill", accent), weight: .semibold),
            Variant(name: "Dot + status", mark: .dot(mint), weight: .medium, subtitle: "Working on 3 tasks"),
        ],
    ]

    struct MarkView: View {
        let mark: Mark
        var body: some View {
            switch mark {
            case .none: EmptyView()
            case let .symbol(name, color):
                Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).frame(width: 16)
            case let .badge(name, color):
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient)
                    .frame(width: 18, height: 18)
                    .overlay(Image(systemName: name).font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            case let .circle(name, color):
                Circle().fill(color.gradient).frame(width: 18, height: 18)
                    .overlay(Image(systemName: name).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white))
            case let .monogram(color):
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient).frame(width: 18, height: 18)
                    .overlay(Text("C").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.white))
            case let .dot(color):
                Circle().fill(color).frame(width: 7, height: 7).frame(width: 12)
            }
        }
    }

    struct Row: View {
        let title: String
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).frame(width: 14)
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 28)
        }
    }

    struct Card: View {
        let v: Variant
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(v.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                        Spacer()
                        Image(systemName: "sidebar.left").foregroundStyle(.white.opacity(0.5)).font(.system(size: 12))
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    header.padding(.top, v.top).padding(.bottom, v.bottom)
                    Row(title: "subrouter 2")
                    Row(title: "cmux mcp recursive")
                    Row(title: "cmux perf lead")
                    Spacer(minLength: 0)
                }
                .frame(width: 240, height: 230, alignment: .top)
                .background(Color(white: 0.145))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08)))
            }
        }

        var header: some View {
            HStack(spacing: 8) {
                MarkView(mark: v.mark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.caps ? "CHIEF" : "Chief")
                        .font(.system(size: v.size, weight: v.weight))
                        .tracking(v.caps ? 0.8 : 0)
                        .foregroundStyle(.white.opacity(v.caps ? 0.6 : 0.95))
                    if let s = v.subtitle {
                        Text(s).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer(minLength: 0)
                if v.trailingAvatar {
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 18, height: 18)
                        .overlay(Text("L").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(v.pill ? RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)) : nil)
            .padding(.horizontal, v.pill ? 6 : 0)
        }
    }

    struct Sheet: View {
        let title: String
        let variants: [Variant]
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    ForEach(0..<3, id: \.self) { r in
                        GridRow {
                            ForEach(0..<3, id: \.self) { c in
                                let i = r * 3 + c
                                if i < variants.count { Card(v: variants[i]) } else { Color.clear.frame(width: 240) }
                            }
                        }
                    }
                }
            }
            .padding(22)
            .background(Color(white: 0.08))
            .environment(\.colorScheme, .dark)
        }
    }

    static let titles = ["1 · Spacing only", "2 · Chief + symbol", "3 · Chief + badge / logo", "4 · Combos"]

    @Test func drawVariationSheets() throws {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, sheet) in Self.sheets.enumerated() {
            let renderer = ImageRenderer(content: Sheet(title: Self.titles[i], variants: sheet))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let url = dir.appending(path: "chief-variations-\(i + 1).png")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
            let b64 = try Data(contentsOf: url).base64EncodedString()
            print("CHIEFPNG-BEGIN-\(i + 1)")
            var idx = b64.startIndex
            while idx < b64.endIndex { let e = b64.index(idx, offsetBy: 4000, limitedBy: b64.endIndex) ?? b64.endIndex; print("CHIEFPNG:\(i + 1):" + b64[idx..<e]); idx = e }
            print("CHIEFPNG-END-\(i + 1)")
        }
    }
}
