import AppKit
import CmuxNextDesign
import SwiftUI
import XCTest

// Design mock: renders a Linear-style "What's new" changelog card in SwiftUI, inside a
// stand-in cmux sidebar, to PNGs under card-shots/ at the checkout's top. Not a product test.

private struct MockRow: View {
    let symbol: String
    let title: String
    var selected = false
    var trailing: String?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(.secondary)
            Text(title).font(Font(Typography.body))
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(Font(Typography.caption)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.primary.opacity(0.08) : .clear))
    }
}

struct ChangelogCardMock: View {
    enum Art { case gradient, none, screenshot }
    var art: Art = .gradient
    var version = "0.62"
    var headline = "Workspace groups"
    var detail = "See your workspaces grouped by repo, at a glance."
    var more = 11
    var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch art {
            case .gradient: banner
            case .screenshot: shot
            case .none: EmptyView()
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("New in \(version)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .opacity(hovered ? 1 : 0.6)
                }
                Text(headline).font(Font(Typography.bodyEmphasized)).foregroundStyle(.primary)
                Text(detail).font(Font(Typography.caption)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 3) {
                    Text("\(more) more changes")
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 3)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovered ? 0.075 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.95), Color(red: 0.20, green: 0.13, blue: 0.45), Color(red: 0.08, green: 0.08, blue: 0.11)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.28), .clear], center: .init(x: 0.25, y: 0.1), startRadius: 2, endRadius: 120)
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 11))
                Text("cmux \(version)").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92)).padding(9)
        }
        .frame(height: 78)
    }

    private var shot: some View {
        ZStack {
            Color(red: 0.13, green: 0.13, blue: 0.15)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(["cmux", "recursive", "website"], id: \.self) { name in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.25)).frame(width: 9, height: 9)
                        Text(name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Capsule().fill(Color(red: 0.36, green: 0.6, blue: 1).opacity(0.8)).frame(width: 18, height: 6)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            .padding(.horizontal, 22).padding(.top, 12).offset(y: 8)
        }
        .frame(height: 78).clipped()
    }
}

private struct SidebarMock<Card: View>: View {
    @ViewBuilder var card: () -> Card
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MockRow(symbol: "house", title: "Home", selected: true)
            MockRow(symbol: "tray", title: "Inbox", trailing: "3")
            Text("Workspaces").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
            MockRow(symbol: "terminal", title: "cmux")
            MockRow(symbol: "terminal", title: "recursive")
            MockRow(symbol: "globe", title: "website")
            MockRow(symbol: "paintpalette", title: "design-system")
            Spacer(minLength: 12)
            card().padding(.bottom, 8)
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(.tertiary)
                Text("Ask anything…").font(Font(Typography.body)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .padding(10)
        .frame(width: 260, height: 520, alignment: .top)
    }
}

final class UpdatedCardMockRenderTests: XCTestCase {
    private var outDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // Tests/CmuxNextSidebarTests/CmuxNext/macOS/Packages
        url.deleteLastPathComponent()
        return url.appendingPathComponent("card-shots", isDirectory: true)
    }

    @MainActor
    private func render<V: View>(_ view: V, _ name: String, dark: Bool) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let bg = dark ? Color(red: 0.105, green: 0.105, blue: 0.115) : Color(red: 0.955, green: 0.955, blue: 0.96)
        let framed = view.background(bg).environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return XCTFail("no image for \(name)") }
        let rep = NSBitmapImageRep(cgImage: cg)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testRenderChangelogCardMocks() throws {
        for dark in [true, false] {
            let s = dark ? "dark" : "light"
            try render(SidebarMock { ChangelogCardMock(art: .gradient) }, "a-banner-\(s)", dark: dark)
            try render(SidebarMock { ChangelogCardMock(art: .screenshot, hovered: true) }, "b-screenshot-\(s)", dark: dark)
            try render(SidebarMock { ChangelogCardMock(art: .none) }, "c-no-art-\(s)", dark: dark)
        }
    }
}
