import AppKit
import CmuxFoundation
import SwiftUI

/// The welcome window's hero: the Cloud tree as the right sidebar shows it
/// mid-work (one machine open on its workspace and two terminals, Terminals
/// selected), floating as a glass panel. The names are illustration, not data,
/// so they are verbatim.
struct CloudWelcomeHero: View {
    var body: some View {
        machineList
            .frame(width: 340)
            .cloudWelcomeGlassPanel(cornerRadius: 14)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var machineList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            row(symbol: "chevron.down", name: "gentle-blue-meerkat")
            row(symbol: "folder.fill", name: "workspace-1", isChild: true, isOpen: true)
            leafRow(symbol: "terminal", name: "codex", depth: 2)
            leafRow(symbol: "terminal", name: "npm run dev", depth: 2)
            HStack(spacing: 2) {
                tab(String(localized: "cloudTree.group.ports", defaultValue: "Ports"), count: 2)
                tab(String(localized: "cloudTree.group.terminals", defaultValue: "Terminals"), count: 2, selected: true)
                tab(String(localized: "cloudTree.group.displays", defaultValue: "Displays"), count: 1)
                tab(String(localized: "cloudTree.group.resources", defaultValue: "Resources"), count: nil)
            }
            .padding(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 0))
            row(symbol: "chevron.right", name: "lucky-ochre-mongoose")
            row(symbol: "chevron.right", name: "loyal-ruby-koi")
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud")
                .cmuxFont(size: 11)
            Text(String(localized: "cloudTree.group.cloudMachines", defaultValue: "Cloud Machines"))
                .cmuxFont(size: 12)
            Text(verbatim: "3/5")
                .cmuxFont(size: 12)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.leading, -1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private func row(symbol: String, name: String, isChild: Bool = false, isOpen: Bool = false) -> some View {
        HStack(spacing: 6) {
            if isChild {
                // A workspace row: disclosure chevron, then its folder.
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            Image(systemName: symbol)
                .cmuxFont(size: isChild ? 11 : 9, weight: isChild ? .regular : .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(verbatim: name)
                .cmuxFont(size: 13)
        }
        .padding(.leading, isChild ? 18 : 0)
        .frame(height: 24)
    }

    private func leafRow(symbol: String, name: String, depth: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(verbatim: name)
                .cmuxFont(size: 13)
        }
        .padding(.leading, CGFloat(depth) * 18 + 20)
        .frame(height: 24)
    }

    private func tab(_ label: String, count: Int?, selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? .primary : .secondary)
            if let count {
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .cmuxFont(size: 11)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0))
        )
    }
}

private extension View {
    /// Liquid Glass on macOS 26; a quiet translucent fill with a hairline before it.
    @ViewBuilder
    func cloudWelcomeGlassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(shape.fill(Color.primary.opacity(0.06)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        }
        #else
        self
            .background(shape.fill(Color.primary.opacity(0.06)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        #endif
    }
}
