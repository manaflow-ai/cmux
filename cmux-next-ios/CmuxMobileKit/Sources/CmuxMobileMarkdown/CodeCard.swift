#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// SPEC 4.6 code card: `codeBg`, radius 20, 40 pt header with language and
/// copy, mono body in a horizontal scroll view, capped height with a fade and
/// "Show all N lines".
public struct CodeCard: View {
    let language: String?
    let code: String
    var title: String?
    var maxHeight: CGFloat
    @State private var expanded = false
    @State private var copied = false
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    /// Settings → Terminal → Wrap code and diff lines.
    @AppStorage(CmuxMobilePreferences.Key.wrapCode) private var wrapCode = CmuxMobilePreferences.defaultWrapCode

    public init(language: String?, code: String, title: String? = nil, maxHeight: CGFloat = 480) {
        self.language = language
        self.code = code
        self.title = title
        self.maxHeight = maxHeight
    }

    private var lineCount: Int { code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var lineHeight: CGFloat { codeSize * 1.46 }
    private var isCapped: Bool { !expanded && CGFloat(lineCount) * lineHeight + 20 > maxHeight }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal) {
                Text(CodeHighlightCache.shared.highlighted(code, language: language))
                    .font(.system(size: codeSize, design: .monospaced))
                    .lineSpacing(codeSize * 0.46)
                    .fixedSize(horizontal: !wrapCode, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    // Wrapping: as wide as the card, so lines break instead of scrolling.
                    .containerRelativeFrame(wrapCode ? .horizontal : [], alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
            .trailingOverflowFade()
            .frame(maxHeight: isCapped ? maxHeight - 40 : nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if isCapped {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.cmuxMobileCodeBackground.opacity(0), .cmuxMobileCodeBackground], startPoint: .top, endPoint: .bottom)
                            .frame(height: 48)
                        Button("Show all \(lineCount) lines") {
                            withAnimation(.cmuxMobileSmooth) { expanded = true }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.cmuxMobileCodeBackground)
                    }
                }
            }
        }
        .background(Color.cmuxMobileCodeBackground, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
            Button("Copy as Markdown", systemImage: "text.document") {
                UIPasteboard.general.string = "```\(language ?? "")\n\(code)\n```"
            }
            ShareLink(item: code) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: language == "diff" ? "plus.forwardslash.minus" : (isShell ? "terminal" : "chevron.left.forwardslash.chevron.right"))
                .font(.system(size: 13))
            Text(title ?? displayLanguage)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .padding(-6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : "Copy code")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: copied) { _, new in new }
    }

    private var isShell: Bool {
        ["bash", "sh", "shell", "zsh", "console"].contains(language?.lowercased() ?? "")
    }

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "Code" }
        let names = ["swift": "Swift", "py": "Python", "python": "Python", "ts": "TypeScript", "typescript": "TypeScript",
                     "js": "JavaScript", "javascript": "JavaScript", "rs": "Rust", "rust": "Rust", "sh": "Bash", "bash": "Bash",
                     "zsh": "Zsh", "diff": "Diff", "json": "JSON", "yaml": "YAML", "toml": "TOML", "go": "Go", "tsx": "TSX", "md": "Markdown"]
        return names[language.lowercased()] ?? language.capitalized
    }

    private func copy() {
        UIPasteboard.general.string = code
        withAnimation(.cmuxMobileSnap) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.cmuxMobileSnap) { copied = false }
        }
    }
}

/// Highlighted code by (language, text); the streaming tail misses, committed cards hit.
@MainActor
final class CodeHighlightCache {
    static let shared = CodeHighlightCache()
    private var cache: [String: AttributedString] = [:]
    private var order: [String] = []

    func highlighted(_ code: String, language: String?) -> AttributedString {
        let key = (language ?? "") + "\u{0}" + code
        if let hit = cache[key] { return hit }
        let value: AttributedString
        if language?.lowercased() == "diff" {
            value = Self.diff(code)
        } else {
            value = SyntaxHighlighter(language: language).highlight(code)
        }
        cache[key] = value
        order.append(key)
        if order.count > 200 { cache[order.removeFirst()] = nil }
        return value
    }

    /// ChatGPT-style diff card: text colors only (SPEC 6.8).
    static func diff(_ code: String) -> AttributedString {
        var output = AttributedString()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(String(line) + (index < lines.count - 1 ? "\n" : ""))
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                piece.foregroundColor = Color(uiColor: .tertiaryLabel)
            } else if line.hasPrefix("@@") {
                piece.foregroundColor = .cmuxMobileSyntaxFunction
            } else if line.hasPrefix("+") {
                piece.foregroundColor = .cmuxMobileDiffAddText
            } else if line.hasPrefix("-") {
                piece.foregroundColor = .cmuxMobileDiffDelText
            }
            output += piece
        }
        return output
    }
}
#endif
