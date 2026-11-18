#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// "Here's how cmux works", setup's first page after sign-in (Claude's
/// post-sign-in explainer): the welcome's art, settled, one title and three
/// rows, then Continue. It is the only page that explains the product; the
/// welcome before sign-in stays free of feature copy (SPEC 5.2).
struct IntroStep: View {
    let next: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        IntroPage(title: "Here's how cmux works") {
            if !dynamicTypeSize.isAccessibilitySize {
                // The welcome's illustration at rest: the Mac, the phone and the chevron.
                WelcomeArt(t: .infinity, idle: nil, width: 180)
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                FirstRunRow(symbol: "desktopcomputer", title: "Agents run on your Mac",
                            detail: "In your projects, with your tools and your keys.")
                FirstRunRow(symbol: "person.crop.circle.badge.checkmark", title: "Chief keeps track",
                            detail: "Tell Chief what you want; it starts agents and follows each one.")
                FirstRunRow(symbol: "iphone", title: "You steer from here",
                            detail: "Answer questions, approve changes and read diffs from your phone.")
            }
            .frame(maxWidth: 360, alignment: .leading)
        } actions: {
            PrimaryCapsule("Continue", action: next)
                .accessibilityIdentifier("setup.intro.continue")
        }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { if DemoDirector.shared.command == .setupContinue { next() } }
        #endif
    }
}

/// "Start your first agent", setup's last page (ChatGPT's and Claude's empty
/// chat): four starter cards and a field to type a task, sent to Chief, which
/// then opens. With no Mac online the task waits in Chief's composer, and the
/// page says so before a tap. "Skip for now" goes to Home.
struct FirstChatStep: View {
    /// The first online Mac of the active space, if any.
    let onlineMac: String?
    /// Whether the account has any Mac (nil: not known yet).
    var accountHasMac: Bool? = nil
    /// Opens Connect your Mac; shown while no Mac is online.
    var connectMac: (() -> Void)? = nil
    /// Sends `prompt` to Chief and leaves setup.
    let start: (String) -> Void
    /// Leaves setup for Home, nothing sent.
    let skip: () -> Void
    @State private var typed = ""
    @State private var started = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var destination: FirstChatDestination { FirstChatDestination(onlineMac: onlineMac, accountHasMac: accountHasMac) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    starters
                        .padding(.top, 24)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // On the scroll view only: an identifier on the whole page replaces its buttons' own.
            .accessibilityIdentifier("setup.first-chat")
            VStack(spacing: 6) {
                field
                TextCTA("Skip for now") {
                    guard !started else { return }
                    started = true
                    skip()
                }
                .accessibilityIdentifier("setup.first-chat.skip")
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, theme.metrics.sideMargin)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            switch DemoDirector.shared.command {
            case .setupFirstChat(let index):
                if FirstChatSuggestion.starters.indices.contains(index) { send(FirstChatSuggestion.starters[index].prompt) }
            case .setupFirstChatType(let text): typed = text
            // Not `.setupNotNow`: the pages under this one on the stack still listen for it.
            default: break
            }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start your first agent")
                .font(theme.type.sidebarTitle)
                .foregroundStyle(theme.colors.label)
                .accessibilityAddTraits(.isHeader)
            Text(destination.subtitle)
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.first-chat.subtitle")
            HStack(spacing: 8) {
                MacStatusChip(destination: destination)
                if destination.offersConnect, let connectMac {
                    Button(action: connectMac) {
                        HStack(spacing: 4) {
                            Text("Connect your Mac")
                            Image(systemName: "chevron.right").font(theme.type.meta.weight(.semibold))
                        }
                        .font(theme.type.meta.weight(.semibold))
                        .foregroundStyle(theme.colors.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.cmuxPressFill)
                    .disabled(started)
                    .accessibilityIdentifier("setup.first-chat.connect-mac")
                }
            }
            .padding(.top, 6)
        }
    }

    /// Two columns at the default text sizes, one at accessibility sizes.
    private var starters: some View {
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(FirstChatSuggestion.starters) { starter in
                Button { send(starter.prompt) } label: { StarterCard(starter: starter) }
                    .buttonStyle(StarterCardStyle())
                    .disabled(started)
                    .accessibilityIdentifier("setup.first-chat.starter.\(starter.id)")
            }
        }
    }

    /// A one-line composer: the task, then the send circle (white in dark,
    /// black in light, SPEC 1.1), disabled until there is text.
    private var field: some View {
        let prompt = FirstChatSuggestion.typedPrompt(typed)
        return HStack(alignment: .center, spacing: 8) {
            // One line, so Return sends (a vertical field would take Return as a newline).
            TextField("Or describe a task…", text: $typed)
                .font(theme.type.body)
                .foregroundStyle(theme.colors.label)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { if let prompt { send(prompt) } }
                .padding(.vertical, 10)
                .padding(.leading, 16)
                .accessibilityIdentifier("setup.first-chat.field")
            Button {
                if let prompt { send(prompt) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.neutralOnAccent)
                    .frame(width: 34, height: 34)
                    .background(theme.colors.neutralAccent.color.opacity(prompt == nil ? 0.3 : 1), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.cmuxPressFill)
            .disabled(prompt == nil || started)
            .padding(.trailing, 6)
            .accessibilityLabel(Text("Send to Chief"))
            .accessibilityIdentifier("setup.first-chat.send")
        }
        .background(theme.colors.surfaceRaised.color, in: .rect(cornerRadius: 22, style: .continuous))
    }

    private func send(_ prompt: String) {
        guard !started else { return }
        started = true
        fieldFocused = false
        theme.haptics.success()
        start(prompt)
    }
}

/// Where the task will run: a green dot and the Mac's name, or a gray dot
/// and "Waiting for your Mac".
private struct MacStatusChip: View {
    let destination: FirstChatDestination

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(destination.isOnline ? theme.colors.success.color : theme.colors.offline.color)
                .frame(width: 8, height: 8)
            Image(systemName: "desktopcomputer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.colors.label2)
            Text(destination.status)
                .font(theme.type.meta.weight(.medium))
                .foregroundStyle(theme.colors.label2)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.colors.fill.color, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.first-chat.status")
    }
}

/// A starter: its symbol, a title and a line, on `surfaceRaised`.
private struct StarterCard: View {
    let starter: FirstChatSuggestion
    /// The symbol grows with the text (capped); its slot is one height for
    /// every symbol, so the titles of a row line up.
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18

    var body: some View {
        let icon = min(iconSize, 32)
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: starter.symbol)
                .font(.system(size: icon, weight: .medium))
                .foregroundStyle(theme.colors.label)
                .frame(height: icon + 4, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(starter.title))
                    .font(theme.type.rowTitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(starter.detail))
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The starter's look: `surfaceRaised` at rest, the pressed wash while held;
/// nothing else changes (design/pressed-state.md).
private struct StarterCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .cmuxMobilePressFill(configuration.isPressed, rest: AnyShapeStyle(theme.colors.surfaceRaised), in: shape)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A row of the intro: a 22 pt symbol, a semibold title, one line under it.
private struct FirstRunRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundStyle(theme.colors.label)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.type.rowTitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                Text(detail)
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The intro's page: art, title and rows centered in the space above the
/// actions, scrolling when the text is large.
private struct IntroPage<Header: View, Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header()
                    Text(title)
                        .font(theme.type.welcomeTitle)
                        .foregroundStyle(theme.colors.label)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                        .accessibilityAddTraits(.isHeader)
                    content()
                        .padding(.top, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center, for: .alignment)
            VStack(spacing: 10) { actions() }
                .frame(maxWidth: 440)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .background(theme.colors.bg.color.ignoresSafeArea())
    }
}
#endif
