#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// SPEC 4.6 code card: the content card level, radius 20, 40 pt header with language and
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
                SelectableText(CodeHighlightCache.shared.highlighted(code, language: language, size: codeSize))
                    .selectionMenu { label in
                        [
                            SelectionMenu.action("Copy Code", "doc.on.doc") { copy() },
                            SelectionMenu.action("Select Code Text", "selection.pin.in.out") {
                                SelectableTextView(code, monospaced: true).present()
                            },
                            SelectionMenu.action("Copy as Markdown", "text.document") {
                                UIPasteboard.general.string = "```\(language ?? "")\n\(code)\n```"
                            },
                            SelectionMenu.share(code, from: label, title: "Share Code")
                        ]
                    }
                    .fixedSize(horizontal: !wrapCode, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    // Wrapping: as wide as the card, so lines break instead of scrolling.
                    .containerRelativeFrame(wrapCode ? .horizontal : [], alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .trailingOverflowFade()
            .frame(maxHeight: isCapped ? maxHeight - 40 : nil, alignment: .top)
            .clipped()
            // Capped: the code fades out above "Show all" through an alpha mask, so the card stays
            // see-through (an opaque band would paint over the Mac's picture).
            .mask {
                if isCapped {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 48)
                        Color.clear.frame(height: 40)
                    }
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .bottom) {
                if isCapped {
                    Button("Show all \(lineCount) lines") {
                        withAnimation(.cmuxMobileSmooth.unlessReduceMotion) { expanded = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(.rect)
                }
            }
        }
        .cmuxMobileContentSurface(.card, in: .rect(cornerRadius: CmuxMobileTheme.standard.metrics.cardRadius, style: .continuous))
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
            .buttonStyle(.cmuxPressFill)
            .accessibilityLabel(copied ? "Copied" : "Copy code")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .cmuxMobileSensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: copied) { _, new in new }
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
        withAnimation(.cmuxMobileSnap.unlessReduceMotion) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.cmuxMobileSnap.unlessReduceMotion) { copied = false }
        }
    }
}

/// Highlighted code by (language, text); the streaming tail misses, committed cards hit.
@MainActor
final class CodeHighlightCache {
    static let shared = CodeHighlightCache()
    private struct Key: Hashable {
        let language: String?
        let code: String
        let size: CGFloat
    }

    private var cache: [Key: NSAttributedString] = [:]
    private var order: [Key] = []

    func highlighted(_ code: String, language: String?, size: CGFloat) -> NSAttributedString {
        let key = Key(language: language, code: code, size: size)
        if let hit = cache[key] { return hit }
        let highlighted = language?.lowercased() == "diff" ? Self.diff(code) : SyntaxHighlighter(language: language).highlight(code)
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.46
        let text = NSMutableAttributedString()
        for run in highlighted.runs {
            let color = run.swiftUI.foregroundColor.map { UIColor($0) } ?? .label
            text.append(NSAttributedString(string: String(highlighted[run.range].characters),
                                           attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        cache[key] = text
        order.append(key)
        if order.count > 200 { cache[order.removeFirst()] = nil }
        return text
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
