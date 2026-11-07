#if os(iOS)
import SwiftUI

private let theme = CmuxMobileTheme.standard

extension View {
    /// Glass circle for floating controls outside toolbars (SPEC 2.4).
    public func cmuxMobileGlassCircle(interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
    }

    /// Glass capsule for banners, toasts and secondary CTAs.
    public func cmuxMobileGlassCapsule(interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }

    /// The composer card: glass, radius 24, with a 1 pt `separator` stroke under
    /// Increase Contrast.
    public func cmuxMobileComposerGlass() -> some View {
        modifier(ComposerGlass())
    }

    /// An inset input field background: `surfaceRaised`, radius 14, at least
    /// 52 tall, growing with its text (Dynamic Type) so it never clips.
    public func cmuxMobileInputField() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: theme.metrics.inputHeight)
            .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.inputRadius, style: .continuous))
    }
}

private struct ComposerGlass: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.metrics.composerRadius, style: .continuous)
        content
            .glassEffect(.regular, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(theme.colors.separator, lineWidth: 1)
                }
            }
    }
}

/// Code entry boxes driven by one hidden `TextField` (SPEC 5.4, 5.6). Six
/// letters and digits for email codes; `groups: [4, 4]` with a dash for Mac
/// pairing. The keyboard follows ``CodeEntryCharacters/keyboard``, and typed,
/// pasted or autofilled text goes through
/// ``CodeEntryCharacters/normalized(_:length:)``.
public struct CodeBoxes: View {
    @Binding var text: String
    let groups: [Int]
    let characters: CodeEntryCharacters
    let contentType: UITextContentType?
    var boxSize: CGSize
    @FocusState private var isFocused: Bool
    /// The boxes grow with the digits' text style.
    @ScaledMetric(relativeTo: .title2) private var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Creates code boxes.
    /// - Parameters:
    ///   - text: The code, normalized by `characters`.
    ///   - groups: Box counts per group, joined by a dash.
    ///   - characters: The accepted characters; also picks the keyboard. No
    ///     default, so each caller states what its code holds.
    ///   - contentType: `.oneTimeCode` so iOS offers the code from Mail or Messages.
    ///   - boxSize: The box size at the default text size.
    public init(text: Binding<String>, groups: [Int] = [6], characters: CodeEntryCharacters, contentType: UITextContentType? = .oneTimeCode, boxSize: CGSize = CmuxMobileTheme.standard.metrics.codeBoxSize) {
        _text = text
        self.groups = groups
        self.characters = characters
        self.contentType = contentType
        self.boxSize = boxSize
    }

    private var length: Int { groups.reduce(0, +) }

    /// The box size at this text size: taller with the digits; wider only at
    /// accessibility sizes (two rows), at most 100 pt so three still fit.
    private var scaledBox: CGSize {
        let factor = max(1, scale)
        let width = dynamicTypeSize.isAccessibilitySize ? min(boxSize.width * factor, 100) : boxSize.width
        return CGSize(width: width, height: boxSize.height * factor)
    }

    public var body: some View {
        ZStack {
            TextField("", text: Binding(get: { text }, set: { newValue in
                text = characters.normalized(newValue, length: length)
            }))
            .textContentType(contentType)
            .keyboardType(characters.keyboard)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($isFocused)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityLabel(Text("Code"))
            // The normalized code (what the boxes show), not the raw field text.
            .accessibilityValue(Text(verbatim: text))

            Group {
                if dynamicTypeSize.isAccessibilitySize, groups.count == 1, length.isMultiple(of: 2) {
                    // Accessibility sizes: two rows (three and three for a code).
                    VStack(spacing: theme.metrics.codeBoxGap) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: theme.metrics.codeBoxGap) {
                                ForEach((row * length / 2)..<((row + 1) * length / 2), id: \.self) { index in
                                    box(at: index)
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: theme.metrics.codeBoxGap) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, count in
                            if groupIndex > 0 {
                                Text(verbatim: "-").font(theme.type.body).foregroundStyle(theme.colors.label3)
                            }
                            let start = groups.prefix(groupIndex).reduce(0, +)
                            ForEach(start..<(start + count), id: \.self) { index in
                                box(at: index)
                            }
                        }
                    }
                }
            }
            .contentShape(.rect)
            .onTapGesture { isFocused = true }
            .accessibilityHidden(true)
        }
        .onAppear { isFocused = true }
    }

    private func box(at index: Int) -> some View {
        let characters = Array(text)
        let character = index < characters.count ? String(characters[index]) : ""
        let isCurrent = isFocused && index == min(characters.count, length - 1)
        return Text(character)
            .font(theme.type.codeDigit)
            .foregroundStyle(theme.colors.label)
            .frame(width: scaledBox.width, height: scaledBox.height)
            .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.codeBoxRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.codeBoxRadius, style: .continuous)
                    .strokeBorder(theme.colors.label, lineWidth: isCurrent ? 2 : 0)
            }
            .animation(theme.motion.snap.animation, value: isCurrent)
    }
}
#endif
