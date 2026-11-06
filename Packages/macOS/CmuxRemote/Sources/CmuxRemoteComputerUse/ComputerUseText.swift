// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Computer Use worker's strings (Resources/Localizable.xcstrings).
struct ComputerUseText: Sendable {
    static func t(_ key: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: key, value: english, table: nil)
    }

    /// "<Agent> wants to use <App>", or "<Agent> on <Machine> wants to use <App>".
    static func approvalTitle(_ question: ApprovalQuestion) -> String {
        let agent = question.agent.isEmpty ? t("computerUse.approval.anAgent", "An agent") : question.agent
        if let machine = question.fromMachine {
            return String(format: t("computerUse.approval.titleRemote", "%1$@ on %2$@ wants to use %3$@"), agent, machine, question.appName)
        }
        return String(format: t("computerUse.approval.title", "%1$@ wants to use %2$@"), agent, question.appName)
    }

    static func approvalDetail(_ question: ApprovalQuestion) -> String {
        question.remember
            ? t("computerUse.approval.detailRemember", "It can see this app's windows and click and type in them. You can change this later in Settings, Computer Use.")
            : t("computerUse.approval.detail", "It can see this app's windows and click and type in them.")
    }

    static func choice(_ answer: ApprovalAnswer, app: String) -> String {
        switch answer {
        case .allowOnce: t("computerUse.approval.allowOnce", "Allow Once")
        case .allowSession: t("computerUse.approval.allowSession", "Allow for This Session")
        case .always: String(format: t("computerUse.approval.always", "Always Allow %@"), app)
        case .deny: t("computerUse.approval.deny", "Deny")
        case .never: t("computerUse.approval.never", "Never")
        case .unavailable: ""
        }
    }
}
