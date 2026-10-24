#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// ``MobilePaywallView`` in its own navigation stack, for presenting as a
/// sheet. Every upgrade entry point opens this same sheet.
///
/// HIG: Sheets (a close button in the toolbar dismisses the sheet).
public struct MobilePaywallSheet: View {
    private let entryPoint: BillingEntryPoint
    private let preview: BillingPaywallPreview?

    /// Creates the sheet.
    /// - Parameters:
    ///   - entryPoint: Where the sheet was opened from.
    ///   - preview: A Paywall Lab preview; nil for the real paywall.
    public init(entryPoint: BillingEntryPoint, preview: BillingPaywallPreview? = nil) {
        self.entryPoint = entryPoint
        self.preview = preview
    }

    public var body: some View {
        NavigationStack {
            MobilePaywallView(entryPoint: entryPoint, preview: preview)
        }
    }
}

extension View {
    /// Presents the paywall while `entryPoint` is non-nil, and sets it back
    /// to nil when the paywall closes. Without a ``BillingModel`` in the
    /// environment nothing is presented: plans are sold only in app (App
    /// Review Guideline 3.1.1).
    ///
    /// ```swift
    /// @State private var paywall: BillingEntryPoint?
    /// Button("Upgrade") { paywall = .settingsUpgradeCard }
    ///     .billingPaywall($paywall)
    /// ```
    /// - Parameters:
    ///   - entryPoint: The entry point to present for; nil hides it.
    ///   - onDismiss: Runs after the paywall closes, for example to reload
    ///     limits that a new plan changed.
    public func billingPaywall(_ entryPoint: Binding<BillingEntryPoint?>, onDismiss: (() -> Void)? = nil) -> some View {
        modifier(BillingPaywallPresenter(entryPoint: entryPoint, onDismiss: onDismiss))
    }

    /// Records `ios_upgrade_entry_viewed` once each time this upgrade card or
    /// banner appears on screen.
    /// - Parameter entryPoint: The entry point the view stands for.
    public func billingUpgradeEntryViewed(_ entryPoint: BillingEntryPoint) -> some View {
        modifier(BillingUpgradeEntryViewedModifier(entryPoint: entryPoint))
    }
}

private struct BillingPaywallPresenter: ViewModifier {
    @Environment(BillingModel.self) private var billing: BillingModel?
    @Binding var entryPoint: BillingEntryPoint?
    let onDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content.sheet(item: presented, onDismiss: onDismiss) { entryPoint in
            MobilePaywallSheet(entryPoint: entryPoint)
                .environment(billing)
        }
    }

    private var presented: Binding<BillingEntryPoint?> {
        Binding(
            get: { billing == nil ? nil : entryPoint },
            set: { entryPoint = $0 }
        )
    }
}

private struct BillingUpgradeEntryViewedModifier: ViewModifier {
    @Environment(BillingModel.self) private var billing: BillingModel?
    let entryPoint: BillingEntryPoint
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                // The Paywall Lab's sample cards are not real entry points.
                guard !isOnScreen, entryPoint != .paywallLab else { return }
                isOnScreen = true
                billing?.upgradeEntryViewed(entryPoint)
            }
            .onDisappear { isOnScreen = false }
    }
}
#endif
