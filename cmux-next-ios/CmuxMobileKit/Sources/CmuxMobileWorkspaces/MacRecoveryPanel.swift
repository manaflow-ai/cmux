#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A Mac's view when the phone cannot use it: what is wrong (offline, not responding, didn't
/// answer, cmux not answering, signed out), when the service last heard from it, and Retry,
/// whose steps show how far it got (cmux#52200).
struct MacRecoveryPanel: View {
    let macName: String
    let reach: MacReachability
    let attempt: MacRecoveryAttempt?
    let now: Date
    let retry: (() -> Void)?
    let signIn: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: reach.symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(theme.colors.label)
                .accessibilityHidden(true)
            Text(reach.title(macName: macName))
                .font(theme.type.emptyTitle)
                .foregroundStyle(theme.colors.label)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .accessibilityIdentifier("mac.recovery.title")
            Text(reach.message(macName: macName, now: now))
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier("mac.recovery.message")
            if let attempt {
                steps(attempt)
                    .padding(.top, 20)
            }
            if reach.action == .signIn, let signIn {
                PrimaryCapsule("Sign In", action: signIn)
                    .padding(.top, 20)
                    .accessibilityIdentifier("mac.recovery.sign-in")
            } else if reach.action == .retry || attempt?.action == .retry, let retry {
                // While a Retry runs the button keeps its word and spins; the steps above say how far it got.
                PrimaryCapsule("Retry", systemImage: "arrow.clockwise", isLoading: attempt?.isRunning == true,
                               action: retry)
                    .padding(.top, 20)
                    .accessibilityIdentifier("mac.recovery.retry")
            }
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, theme.metrics.sideMargin)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("mac.recovery")
    }

    /// "✓ Reaching the cmux service / ◌ Reaching Cosmic Gray / ○ Opening your sessions", then
    /// the outcome: whether the retry reached the Mac and what to do next.
    private func steps(_ attempt: MacRecoveryAttempt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MacRecoveryAttempt.Step.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    stepMark(step, attempt)
                        .frame(width: 22, height: 22)
                    Text(step.label(macName: macName) + (attempt.isRunning && step == attempt.step ? "…" : ""))
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(step > attempt.step ? theme.colors.label2 : theme.colors.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(step.label(macName: macName)), \(stateWord(step, attempt))"))
            }
            if let outcome = attempt.outcome(macName: macName) {
                Text(outcome)
                    .font(theme.type.rowSubtitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .accessibilityIdentifier("mac.recovery.outcome")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("mac.recovery.steps")
    }

    @ViewBuilder private func stepMark(_ step: MacRecoveryAttempt.Step, _ attempt: MacRecoveryAttempt) -> some View {
        switch stateWord(step, attempt) {
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.colors.label)
        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(theme.colors.label)
        case "in progress": CmuxSpinner()
        default: Image(systemName: "circle").foregroundStyle(theme.colors.label2)
        }
    }

    private func stateWord(_ step: MacRecoveryAttempt.Step, _ attempt: MacRecoveryAttempt) -> String {
        if step < attempt.step { return "done" }
        if step > attempt.step { return "not started" }
        switch attempt.result {
        case nil: return "in progress"
        case .connected: return "done"
        case .failed: return "failed"
        }
    }
}
#endif
