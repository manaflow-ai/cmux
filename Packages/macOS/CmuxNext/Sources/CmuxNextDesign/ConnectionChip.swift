public import CmuxNextDesignTokens
public import SwiftUI
import CmuxNextWakeups

/// A connection state drawn as a small chip over the content, never a row or a sentence that pushes it (Leo,
/// 2026-11-21: "typically for these connection indicstors you can just put a small unobtrusive thing somewhere
/// without needing to block any content ... a symbol or short thing, not a sentence. stop layout shifting").
///
/// ``SwiftUI/View/connectionChip(_:symbol:alignment:)`` lays it over its content with `.overlay`, so the content's
/// frame is the same connected, reconnecting or offline; it shows only once the state has lasted
/// ``NoticeTiming/connectionQuiet`` (a blip says nothing). Its words are one or two (`word`); the long form stays
/// its accessibility label and help.
public struct ConnectionChip: View {
    public let word: String
    public let symbol: String
    public let detail: String?

    public init(_ word: String, symbol: String = "wifi.slash", detail: String? = nil) {
        self.word = word
        self.symbol = symbol
        self.detail = detail
    }

    public var body: some View {
        Label(word, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(Font(Typography.system(size: TypeScale.caption, weight: TypeScale.emphasis)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .help(detail ?? word)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail ?? word)
    }
}

extension EnvironmentValues {
    /// How long a connection state lasts before its chip shows: ``NoticeTiming/connectionQuiet``; tests set zero.
    @Entry public var connectionQuietDelay: Duration = NoticeTiming.connectionQuiet
}

/// Whether `active` has lasted ``NoticeTiming/connectionQuiet`` (the environment's `connectionQuietDelay`). One
/// ``QuietHold`` (a ``DemandTimer``) per stretch, cancelled when the state ends; nothing runs while connected.
struct ConnectionLasting: ViewModifier {
    let active: Bool
    @Binding var lasted: Bool
    @Environment(\.connectionQuietDelay) private var delay
    @State private var hold: QuietHold?

    func body(content: Content) -> some View {
        content
            .onAppear { follow(active) }
            .onChange(of: active) { _, now in follow(now) }
            .onDisappear { hold?.update(false) {} }
    }

    private func follow(_ now: Bool) {
        guard now else {
            hold?.update(false) {}
            lasted = false
            return
        }
        guard delay > .zero else {
            lasted = true
            return
        }
        let quiet = hold ?? QuietHold(owner: "ConnectionChip.lasting", delay: delay)
        hold = quiet
        let shown = $lasted
        quiet.update(true) { shown.wrappedValue = true }
    }
}

private struct ConnectionChipOverlay: ViewModifier {
    let word: String?
    let symbol: String
    let detail: String?
    let alignment: Alignment
    @State private var lasted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if lasted, let word {
                    ConnectionChip(word, symbol: symbol, detail: detail)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .modifier(ConnectionLasting(active: word != nil, lasted: $lasted))
    }
}

extension View {
    /// Lays a ``ConnectionChip`` over this view while `word` is non-nil and has been for
    /// ``NoticeTiming/connectionQuiet``. It takes no layout space: the view's frame never changes with the link.
    /// `word` is one or two words ("Offline", "Reconnecting"); `detail` is the long form for help and VoiceOver.
    public func connectionChip(_ word: String?, symbol: String = "wifi.slash", detail: String? = nil,
                               alignment: Alignment = .topTrailing) -> some View {
        modifier(ConnectionChipOverlay(word: word, symbol: symbol, detail: detail, alignment: alignment))
    }

    /// `lasted` turns true once `active` has held for ``NoticeTiming/connectionQuiet`` and false when it ends:
    /// the gate for a connection state drawn in space that is always reserved.
    public func connectionLasting(_ active: Bool, lasted: Binding<Bool>) -> some View {
        modifier(ConnectionLasting(active: active, lasted: lasted))
    }
}
