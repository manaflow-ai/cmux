#if os(iOS)
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxSpinner
import SwiftUI

/// acpmux's sudo card on the phone (hub/elevation.rs): who asks, the exact command sudo runs on
/// the Mac, the agent's reason, a password field, Approve and Deny. It takes the composer's place
/// while it waits, as the permission bar does. Approve signs with this phone's approval key; the
/// password goes to acpmux only and the field empties as it is sent. Deny is final.
public struct ElevationCard: View {
    let ask: AgentElevationAsk
    let agentName: String
    let sending: Bool
    let answer: (String?) -> Void
    @State private var password = ""
    /// What the last Approve sent, until its answer: a send that fails (the card is still here
    /// when `sending` ends) puts it back so the person need not type it again, as the Mac card does.
    @State private var sent: String?
    @FocusState private var focused: Bool

    public init(ask: AgentElevationAsk, agentName: String, sending: Bool, answer: @escaping (String?) -> Void) {
        self.ask = ask
        self.agentName = agentName
        self.sending = sending
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(agentName) asks to run this as root on \(ask.host)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            CodeCard(language: "bash", code: ask.commandLine, title: "Command", maxHeight: 6 * 19 + 60)
            if !ask.reason.isEmpty {
                Text(ask.reason).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password for sudo", text: $password)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(approve)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                Button("Deny") { answer(nil) }
                    .buttonStyle(CmuxMobileCapsuleButtonStyle(.destructive, size: .bar))
                    .disabled(sending)
                Button(action: approve) {
                    HStack(spacing: 6) {
                        if sending { CmuxSpinner(tint: Color.cmuxMobileOnAccent).controlSize(.small).accessibilityHidden(true) }
                        Text(sending ? PermissionActionBar.sendingAllow : "Approve")
                    }
                }
                .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary, size: .bar))
                .disabled(password.isEmpty || sending)
            }
        }
        .onChange(of: sending) { was, now in
            guard was, !now else { return }
            if password.isEmpty, let sent { password = sent }
            sent = nil
        }
    }

    private var note: String {
        let base = "Your password goes only to sudo on the Mac; the agent never sees it. It covers this one command."
        guard let seconds = ask.timeoutSecs else { return base }
        return base + " Stops after \(seconds) s."
    }

    private func approve() {
        guard !password.isEmpty, !sending else { return }
        let value = password
        sent = value
        password = ""
        focused = false
        answer(value)
    }
}
#endif
