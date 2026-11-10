#if os(iOS)
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The global connection banner states (SPEC 7.4).
public struct ConnectionBannerState: Sendable, Hashable {
    public let symbol: String?
    public let showsSpinner: Bool
    public let text: String
    /// A second line, smaller, for what to do next (pairing: where the Mac asks).
    public var detail: String? = nil
    public var offersRetry = false
    /// The action button's title when it is not "Retry" (signed out: "Sign in").
    public var actionTitle: String? = nil
    /// Stable identity so two Macs with the same state still refresh the banner.
    public var identity: String? = nil

    public static func reconnecting(to mac: String, identity: String? = nil) -> Self { Self(symbol: nil, showsSpinner: true, text: "Reconnecting…", identity: identity ?? mac) }
    public static let offline = Self(symbol: "wifi.slash", showsSpinner: false, text: "Offline", offersRetry: true)
    public static func macOffline(_ mac: String, identity: String? = nil) -> Self { Self(symbol: "moon.zzz", showsSpinner: false, text: "Offline", offersRetry: true, identity: identity ?? mac) }
    public static let connected = Self(symbol: "checkmark", showsSpinner: false, text: "Connected")
    public static func connecting(to mac: String, identity: String? = nil) -> Self { Self(symbol: nil, showsSpinner: true, text: "Reconnecting…", identity: identity ?? mac) }
    /// The account's session was revoked: nothing reconnects until the person
    /// signs in again, which the banner's one button starts.
    public static let signedOut = Self(symbol: "person.crop.circle.badge.exclamationmark", showsSpinner: false,
                                       text: String(localized: "This device was signed out. Sign in again"),
                                       offersRetry: true, actionTitle: String(localized: "Sign in"))
    public static let connectionFailed = Self(symbol: "exclamationmark.triangle", showsSpinner: false, text: "Offline", offersRetry: true)
    /// An application failure distinct from connection state.
    public static func failed(_ text: String, identity: String? = nil) -> Self {
        Self(symbol: "exclamationmark.triangle", showsSpinner: false, text: text, identity: identity)
    }

    /// Gives a banner a stable owner without changing its copy. The owner keeps
    /// dismissal scoped to the Mac that produced the banner.
    public func identified(_ identity: String?) -> Self {
        var copy = self
        copy.identity = identity
        return copy
    }
    /// The Mac asks "Allow … to connect?" for this phone
    /// (verify/phone-approvals.md): a notification, a Dock bounce and
    /// Settings → Mobile on a Mac with #20491, only a cmux dialog on an older
    /// one. "Look for cmux" is true for both.
    public static func waitingForPairing(on mac: String, identity: String? = nil) -> Self {
        Self(symbol: "lock.shield", showsSpinner: true, text: String(localized: "Approve this iPhone on \(mac)"),
             detail: String(localized: "Look for cmux on your Mac"), identity: identity ?? mac)
    }
    /// The same after the phone replaced an unreadable stored key.
    public static func waitingForPairingAfterNewKeys(on mac: String, identity: String? = nil) -> Self {
        Self(symbol: "lock.shield", showsSpinner: true, text: String(localized: "Approve this iPhone again on \(mac)"),
             detail: String(localized: "Its keys were reset. Look for cmux on your Mac."), identity: identity ?? mac)
    }
}

/// Glass banner, `footnote` semibold: a 36 pt capsule when it fits on one
/// line, else a wrapped card (the corner radius of a card), with the action
/// under the text at accessibility sizes. Use `.cmuxMobileBanner(_:)` to place
/// it under the toolbar with the `snappy` enter/exit.
public struct ConnectionBanner: View {
    let state: ConnectionBannerState

    let retry: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ state: ConnectionBannerState, retry: (() -> Void)? = nil) {
        self.state = state
        self.retry = retry
    }

    public var body: some View {
        // One line when it fits; a long message (signed out) or a large text
        // size wraps instead of clipping.
        ViewThatFits(in: .horizontal) {
            if state.detail == nil { oneLine }
            wrapped
        }
        .font(theme.type.meta.weight(.semibold))
        .foregroundStyle(theme.colors.label)
        // A banner over the list: readable, never a wall of text.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 16)
        .accessibilityElement(children: action != nil ? .contain : .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var action: (() -> Void)? { state.offersRetry ? retry : nil }

    private var oneLine: some View {
        HStack(spacing: 8) {
            leading
            Text(state.text).lineLimit(1)
            if let action {
                Text("·").accessibilityHidden(true)
                actionButton(action)
            }
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var wrapped: some View {
        let stacked = typeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.text)
                    if let detail = state.detail {
                        // Two lines: what to do, then where (the Mac's notification).
                        Text(detail)
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let action, !stacked {
                    Text("·").accessibilityHidden(true)
                    actionButton(action).fixedSize()
                }
            }
            if let action, stacked { actionButton(action) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .glassEffect(.regular, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
    }

    @ViewBuilder private var leading: some View {
        if state.showsSpinner {
            CmuxSpinner().controlSize(.small)
        } else if let symbol = state.symbol {
            Image(systemName: symbol)
        }
    }

    private func actionButton(_ action: @escaping () -> Void) -> some View {
        Button(state.actionTitle ?? String(localized: "Retry"), action: action)
            .buttonStyle(.plain)
            .accessibilityIdentifier(state.actionTitle == nil ? "connection.retry" : "connection.action")
    }
}
#endif
