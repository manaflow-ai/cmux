#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct AgentFeedRowActions {
    let setExpanded: @MainActor (Bool) -> Void
    let setDraft: @MainActor (String) -> Void
    let setPlanFeedback: @MainActor (String) -> Void
    let setQuestionSelection: @MainActor (String, Set<String>) -> Void
    let setOtherAnswer: @MainActor (String, String) -> Void
    let setFormValue: @MainActor (String, String) -> Void
    let reply: @MainActor () -> Void
    let decide: @MainActor (MobileAgentFeedAction) -> Void
    let open: @MainActor () -> Void
}

struct AgentFeedRow: View, Equatable {
    let item: MobileAgentFeedItem
    let design: MobileAgentFeedDesign
    let requiresResponse: Bool
    let isExpanded: Bool
    let draft: String
    let mutationState: MobileAgentFeedMutationState
    let interactionsEnabled: Bool
    let planFeedback: String
    let questionSelections: [String: Set<String>]
    let otherAnswers: [String: String]
    let formValues: [String: String]
    let actions: AgentFeedRowActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.agentFeedLocalizer) private var localizer
    private var copy: AgentFeedRowCopy { AgentFeedRowCopy(localizer: localizer) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.design == rhs.design
            && lhs.requiresResponse == rhs.requiresResponse
            && lhs.isExpanded == rhs.isExpanded
            && lhs.draft == rhs.draft
            && lhs.mutationState == rhs.mutationState
            && lhs.interactionsEnabled == rhs.interactionsEnabled
            && lhs.planFeedback == rhs.planFeedback
            && lhs.questionSelections == rhs.questionSelections
            && lhs.otherAnswers == rhs.otherAnswers
            && lhs.formValues == rhs.formValues
    }

    var body: some View {
        AgentFeedRowChrome(
            design: design,
            sourceLabel: copy.sourceLabel(item.wire.source),
            isActionable: requiresResponse,
            actionNeededLabel: localizer.string(
                "mobile.agentFeed.chrome.actionNeeded",
                defaultValue: "Action needed"
            ),
            activityLabel: localizer.string(
                "mobile.agentFeed.chrome.activity",
                defaultValue: "Activity"
            )
        ) {
            VStack(alignment: .leading, spacing: design == .compact ? 6 : 10) {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { isExpanded },
                        set: { newValue in actions.setExpanded(newValue) }
                    )
                ) {
                    actionArea
                } label: {
                    VStack(alignment: .leading, spacing: design == .compact ? 6 : 10) {
                        AgentFeedRowHeader(
                            item: item,
                            design: design,
                            requiresResponse: requiresResponse,
                            localizer: localizer
                        )
                        AgentFeedContext(
                            item: item,
                            isExpanded: isExpanded,
                            requiresResponse: requiresResponse,
                            interactionsEnabled: interactionsEnabled,
                            localizer: localizer
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(disclosureAccessibilityLabel)
                    .accessibilityIdentifier("MobileAgentFeedExpand-\(suffix)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                footer
            }
            .padding(.vertical, design == .compact ? 2 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentFeedCard-\(suffix)")
    }

    @ViewBuilder
    private var footer: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                mutationCaption
                openAgentControl
            }
        } else {
            HStack {
                mutationCaption
                Spacer()
                openAgentControl
            }
        }
    }

    @ViewBuilder
    private var openAgentControl: some View {
        if item.wire.workspaceID != nil, item.wire.surfaceID != nil {
            Button(action: actions.open) {
                Label(
                    localizer.string("mobile.agentFeed.openAgent", defaultValue: "Open Agent"),
                    systemImage: "terminal"
                )
            }
            .frame(minHeight: 44)
            .buttonStyle(.borderless)
            .disabled(!interactionsEnabled)
            .accessibilityIdentifier("MobileAgentFeedOpenAgent-\(suffix)")
        } else {
            Text(localizer.string("mobile.agentFeed.targetUnavailable", defaultValue: "Agent location unavailable"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch item.wire.payload {
        case .permission(_, let toolName, let safeInput, let supportedModes)
            where requiresResponse:
            VStack(alignment: .leading, spacing: 8) {
                Text(toolName).font(.headline)
                if !safeInput.isEmpty { Text(safeInput).font(.caption).foregroundStyle(.secondary) }
                if supportedModes.isEmpty {
                    Text(localizer.string(
                        "mobile.agentFeed.permission.malformed",
                        defaultValue: "No inline permission options were provided. Open Agent to respond."
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    ViewThatFits {
                        HStack { permissionButtons(supportedModes) }
                        VStack(alignment: .leading) { permissionButtons(supportedModes) }
                    }
                }
            }
        case .exitPlan(_, let plan, let summary, _) where requiresResponse:
            VStack(alignment: .leading, spacing: 8) {
                if let summary { Text(summary).font(.headline) }
                Text(plan).font(.body).textSelection(.enabled)
                TextField(
                    localizer.string("mobile.agentFeed.plan.feedback", defaultValue: "Request changes"),
                    text: Binding(get: { planFeedback }, set: { actions.setPlanFeedback($0) }),
                    axis: .vertical
                )
                .lineLimit(2...6)
                .disabled(!interactionsEnabled || isSending)
                .accessibilityIdentifier("MobileAgentFeedPlanFeedback-\(suffix)")
                ViewThatFits {
                    HStack { planButtons }
                    VStack(alignment: .leading) { planButtons }
                }
            }
        case .question(_, let questions) where requiresResponse:
            if questions.isEmpty {
                Text(localizer.string("mobile.agentFeed.question.malformed", defaultValue: "This question could not be displayed. Open the agent to respond."))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(questions) { question in questionView(question) }
                    Button(localizer.string("mobile.agentFeed.question.submit", defaultValue: "Submit Answers")) {
                        actions.decide(.question(selections: encodedQuestionAnswers(questions)))
                    }
                    .disabled(!interactionsEnabled || isSending || !questionsAreValid(questions))
                    .frame(minHeight: 44)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("MobileAgentFeedQuestionSubmit-\(suffix)")
                }
            }
        case .boolean(_, let prompt, let yesLabel, let noLabel, let defaultValue) where requiresResponse:
            let resolvedYesLabel = booleanLabel(yesLabel, value: true)
            let resolvedNoLabel = booleanLabel(noLabel, value: false)
            VStack(alignment: .leading, spacing: 10) {
                Text(prompt).font(.headline)
                ViewThatFits {
                    HStack {
                        booleanButton(label: resolvedNoLabel, value: false, systemImage: "xmark.circle")
                        booleanButton(label: resolvedYesLabel, value: true, systemImage: "checkmark.circle")
                    }
                    VStack(alignment: .leading) {
                        booleanButton(label: resolvedNoLabel, value: false, systemImage: "xmark.circle")
                        booleanButton(label: resolvedYesLabel, value: true, systemImage: "checkmark.circle")
                    }
                }
                if let defaultValue {
                    Text(defaultValue ? resolvedYesLabel : resolvedNoLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        case .form(_, let title, let fields, let externalURL) where requiresResponse:
            formView(title: title, fields: fields, externalURL: externalURL)
        case .stop where requiresResponse:
            turnCompletionActionArea
        case .lifecycle where item.isTurnCompletion && requiresResponse:
            turnCompletionActionArea
        case .unknown where requiresResponse:
            Text(localizer.string(
                "mobile.agentFeed.action.unsupported",
                defaultValue: "This request needs a newer version of cmux. Open Agent to respond."
            ))
            .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func permissionButtons(_ modes: [String]) -> some View {
        ForEach(modes, id: \.self) { mode in
            Button(copy.permissionModeLabel(mode, source: item.wire.source)) {
                actions.decide(.permission(mode: mode))
            }
                .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("MobileAgentFeedPermission-\(mode)-\(suffix)")
        }
    }

    @ViewBuilder
    private func booleanButton(label: String, value: Bool, systemImage: String) -> some View {
        Button {
            actions.decide(.boolean(value: value))
        } label: {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("MobileAgentFeedBoolean-\(value)-\(suffix)")
    }

    @ViewBuilder
    private func formView(
        title: String?,
        fields: [MobileWorkstreamQuestion],
        externalURL: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title, !title.isEmpty { Text(title).font(.headline) }
            if fields.isEmpty {
                Text(localizer.string(
                    "mobile.agentFeed.form.malformed",
                    defaultValue: "This form could not be displayed. Open the agent to respond."
                ))
                .foregroundStyle(.secondary)
            } else {
                ForEach(fields) { field in formFieldView(field) }
            }
            if let externalURL, let url = safeExternalURL(externalURL) {
                Link(destination: url) {
                    Label(
                        localizer.string("mobile.agentFeed.form.open", defaultValue: "Open form"),
                        systemImage: "arrow.up.right.square"
                    )
                }
                .frame(minHeight: 44)
            }
            if fields.contains(where: { normalizedInputType($0.inputType) != "external" }) {
                Button(
                    localizer.string("mobile.agentFeed.form.submit", defaultValue: "Submit Form")
                ) {
                    actions.decide(.form(
                        action: "accept",
                        selections: formSelectionsForSubmission(fields)
                    ))
                }
                .disabled(!interactionsEnabled || isSending || fields.isEmpty || !formIsValid(fields))
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("MobileAgentFeedFormSubmit-\(suffix)")
            }
            if item.wire.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex" {
                ViewThatFits {
                    HStack { formDismissalButtons }
                    VStack(alignment: .leading) { formDismissalButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var formDismissalButtons: some View {
        Button(localizer.string("mobile.agentFeed.form.decline", defaultValue: "Decline")) {
            actions.decide(.form(action: "decline", selections: []))
        }
        .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
        .frame(minHeight: 44)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("MobileAgentFeedFormDecline-\(suffix)")

        Button(localizer.string("mobile.agentFeed.form.cancel", defaultValue: "Cancel")) {
            actions.decide(.form(action: "cancel", selections: []))
        }
        .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
        .frame(minHeight: 44)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("MobileAgentFeedFormCancel-\(suffix)")
    }

    @ViewBuilder
    private func formFieldView(_ field: MobileWorkstreamQuestion) -> some View {
        let inputType = normalizedInputType(field.inputType)
        VStack(alignment: .leading, spacing: 6) {
            Text(field.prompt).font(.subheadline.weight(.semibold))
            switch inputType {
            case "external":
                EmptyView()
            case "choice":
                ForEach(field.options) { option in
                    Button {
                        var selections = questionSelections[field.id] ?? []
                        if field.multiSelect {
                            if selections.contains(option.id) {
                                selections.remove(option.id)
                            } else {
                                selections.insert(option.id)
                            }
                        } else {
                            selections = [option.id]
                        }
                        actions.setQuestionSelection(field.id, selections)
                    } label: {
                        HStack {
                            Image(
                                systemName: formSelectionSymbol(field, option.id)
                            )
                            Text(option.label)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .disabled(!interactionsEnabled || isSending)
                }
            case "boolean":
                Toggle(
                    field.placeholder ?? localizer.string("mobile.agentFeed.form.boolean", defaultValue: "Enable"),
                    isOn: Binding(
                        get: { Self.decodeBool(formValues[field.id] ?? field.defaultValue ?? "") ?? false },
                        set: { actions.setFormValue(field.id, $0 ? "true" : "false") }
                    )
                )
                .disabled(!interactionsEnabled || isSending)
            case "secret":
                SecureField(
                    field.placeholder ?? localizer.string("mobile.agentFeed.form.value", defaultValue: "Value"),
                    text: Binding(
                        get: { formValues[field.id] ?? field.defaultValue ?? "" },
                        set: { actions.setFormValue(field.id, $0) }
                    )
                )
                .disabled(!interactionsEnabled || isSending)
            default:
                TextField(
                    field.placeholder ?? localizer.string("mobile.agentFeed.form.value", defaultValue: "Value"),
                    text: Binding(
                        get: { formValues[field.id] ?? field.defaultValue ?? "" },
                        set: { actions.setFormValue(field.id, $0) }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textInputAutocapitalization(inputType == "url" ? .never : .sentences)
                .disabled(!interactionsEnabled || isSending)
            }
        }
    }

    private func normalizedInputType(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "choice", "select", "enum", "radio", "multiselect", "multi_select": return "choice"
        case "boolean", "bool", "confirmation", "confirm", "yes_no": return "boolean"
        case "number", "decimal": return "number"
        case "integer", "int": return "integer"
        case "url", "uri": return "url"
        case "email": return "email"
        case "date": return "date"
        case "datetime", "date_time", "date-time": return "date_time"
        case "secret", "password": return "secret"
        case "external", "external_url", "link": return "external"
        default: return "text"
        }
    }

    private func safeExternalURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func formIsValid(_ fields: [MobileWorkstreamQuestion]) -> Bool {
        fields.allSatisfy(fieldValueIsValid)
    }

    private func fieldValueIsValid(_ field: MobileWorkstreamQuestion) -> Bool {
        let inputType = normalizedInputType(field.inputType)
        // URL-mode elicitation is completed by the agent server after the
        // external page closes. It is not a value the Feed form submits.
        if inputType == "external" { return true }
        if inputType == "choice" {
            let selections = questionSelections[field.id]
                ?? field.defaultValue.map { Set([$0]) }
                ?? []
            guard !selections.isEmpty || field.required == false,
                  field.multiSelect || selections.count <= 1,
                  field.minSelections.map({ selections.count >= $0 }) ?? true,
                  field.maxSelections.map({ selections.count <= $0 }) ?? true else { return false }
            let optionIDs = Set(field.options.map(\.id))
            return selections.allSatisfy(optionIDs.contains)
        }
        let value = (formValues[field.id]
            ?? field.defaultValue
            ?? (inputType == "boolean" ? "false" : ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return field.required == false
        }
        switch inputType {
        case "boolean":
            return Self.decodeBool(value) != nil
        case "number":
            guard let number = Double(value) else { return false }
            return number.isFinite
                && (field.minimum.map { number >= $0 } ?? true)
                && (field.maximum.map { number <= $0 } ?? true)
        case "integer":
            guard let number = Double(value) else { return false }
            return number.isFinite
                && number.rounded(.towardZero) == number
                && (field.minimum.map { number >= $0 } ?? true)
                && (field.maximum.map { number <= $0 } ?? true)
        case "url":
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased() else { return false }
            return !scheme.isEmpty && stringLengthIsValid(value, field: field)
        case "email":
            let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
            return pieces.count == 2
                && !pieces[0].isEmpty
                && !pieces[1].isEmpty
                && !value.contains(where: \.isWhitespace)
                && stringLengthIsValid(value, field: field)
        case "date":
            return validISODate(value) && stringLengthIsValid(value, field: field)
        case "date_time":
            return ISO8601DateFormatter().date(from: value) != nil
                && stringLengthIsValid(value, field: field)
        default:
            return stringLengthIsValid(value, field: field)
        }
    }

    private func formSelectionsForSubmission(
        _ fields: [MobileWorkstreamQuestion]
    ) -> [String] {
        fields.flatMap { field -> [String] in
            let inputType = normalizedInputType(field.inputType)
            if inputType == "external" { return [] }
            if inputType == "choice" {
                let selections = questionSelections[field.id]
                    ?? field.defaultValue.map { Set([$0]) }
                    ?? []
                return selections.sorted().map { "\(field.id)=\($0)" }
            }
            let value = formValues[field.id]
                ?? field.defaultValue
                ?? (inputType == "boolean" ? "false" : "")
            return value.isEmpty ? [] : ["\(field.id)=\(value)"]
        }
    }

    private func formSelectionSymbol(
        _ field: MobileWorkstreamQuestion,
        _ optionID: String
    ) -> String {
        let selections = questionSelections[field.id]
            ?? field.defaultValue.map { Set([$0]) }
            ?? []
        let selected = selections.contains(optionID)
        if field.multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func stringLengthIsValid(
        _ value: String,
        field: MobileWorkstreamQuestion
    ) -> Bool {
        (field.minLength.map { value.count >= $0 } ?? true)
            && (field.maxLength.map { value.count <= $0 } ?? true)
    }

    private func validISODate(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10,
              pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) != nil
    }

    @ViewBuilder
    private var planButtons: some View {
        ForEach(["ultraplan", "bypassPermissions", "autoAccept", "manual", "deny"], id: \.self) { mode in
            Button(copy.planModeLabel(mode)) {
                actions.decide(.exitPlan(
                    mode: mode,
                    feedback: planFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : planFeedback
                ))
            }
            .disabled(!interactionsEnabled || isSending || !item.wire.status.isPending)
            .frame(minHeight: 44)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("MobileAgentFeedPlan-\(mode)-\(suffix)")
        }
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                localizer.string("mobile.agentFeed.reply.placeholder", defaultValue: "Reply to this agent"),
                text: Binding(get: { draft }, set: { actions.setDraft($0) }),
                axis: .vertical
            )
            .lineLimit(2...8)
            .disabled(!interactionsEnabled || isSending)
            .accessibilityIdentifier("MobileAgentFeedReplyComposer-\(suffix)")
            Button(localizer.string("mobile.agentFeed.reply.send", defaultValue: "Send Reply"), action: actions.reply)
                .disabled(!interactionsEnabled || isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.wire.surfaceID == nil)
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("MobileAgentFeedReplySubmit-\(suffix)")
        }
    }

    /// A completed turn is only replyable while its exact route is live. When
    /// the row came from cache, a disconnected Mac, or a stale route, do not
    /// leave a disabled editor on screen. Show the final answer when the host
    /// captured one, otherwise make the absence of a response explicit.
    @ViewBuilder
    private var turnCompletionActionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if interactionsEnabled {
                replyComposer
            } else if item.wire.lastAssistantMessage == nil {
                Text(localizer.string(
                    "mobile.agentFeed.card.noResponse",
                    defaultValue: "No response. The agent stopped waiting."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func questionView(_ question: MobileWorkstreamQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if question.inputType != nil,
               normalizedInputType(question.inputType) != "choice" {
                formFieldView(question)
            } else {
                if let header = question.header { Text(header).font(.caption.weight(.semibold)) }
                Text(question.prompt).font(.headline)
                ForEach(question.options) { option in
                    Button {
                        var selections = questionSelections[question.id] ?? []
                        if question.multiSelect {
                            if selections.contains(option.id) { selections.remove(option.id) } else { selections.insert(option.id) }
                        } else {
                            selections = [option.id]
                        }
                        actions.setQuestionSelection(question.id, selections)
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: selectionSymbol(question, option.id))
                            VStack(alignment: .leading) {
                                Text(option.label)
                                if let description = option.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .disabled(!interactionsEnabled || isSending)
                    .accessibilityIdentifier("MobileAgentFeedQuestion-\(question.id)-\(option.id)-\(suffix)")
                }
                if question.allowsOther != false {
                    TextField(
                        localizer.string("mobile.agentFeed.question.other", defaultValue: "Other"),
                        text: Binding(
                            get: { otherAnswers[question.id] ?? "" },
                            set: { actions.setOtherAnswer(question.id, $0) }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .disabled(!interactionsEnabled || isSending)
                    .accessibilityIdentifier("MobileAgentFeedQuestionOther-\(question.id)-\(suffix)")
                }
            }
        }
    }

    private func selectionSymbol(_ question: MobileWorkstreamQuestion, _ optionID: String) -> String {
        let selected = questionSelections[question.id]?.contains(optionID) == true
        if question.multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func questionsAreValid(_ questions: [MobileWorkstreamQuestion]) -> Bool {
        questions.allSatisfy { question in
            if question.inputType != nil,
               normalizedInputType(question.inputType) != "choice" {
                return fieldValueIsValid(question)
            }
            let selectedCount = (questionSelections[question.id] ?? []).count
            let hasOther = !(otherAnswers[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let answerCount = selectedCount + (hasOther ? 1 : 0)
            if answerCount == 0 {
                return question.required == false && (question.minSelections ?? 0) == 0
            }
            guard question.multiSelect || answerCount == 1,
                  question.minSelections.map({ answerCount >= $0 }) ?? true,
                  question.maxSelections.map({ answerCount <= $0 }) ?? true else { return false }
            let optionIDs = Set(question.options.map(\.id))
            let selectedAreValid = (questionSelections[question.id] ?? []).allSatisfy(optionIDs.contains)
            return selectedAreValid && (!hasOther || question.allowsOther != false)
        }
    }

    private func encodedQuestionAnswers(_ questions: [MobileWorkstreamQuestion]) -> [String] {
        questions.flatMap { question in
            if question.inputType != nil,
               normalizedInputType(question.inputType) != "choice" {
                let inputType = normalizedInputType(question.inputType)
                let value = (formValues[question.id]
                    ?? question.defaultValue
                    ?? (inputType == "boolean" ? "false" : ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? [] : ["\(question.id)=\(value)"]
            }
            let selected = (questionSelections[question.id] ?? []).sorted().map { "\(question.id)=\($0)" }
            let other = (otherAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return selected + (other.isEmpty ? [] : ["\(question.id)=other:\(other)"])
        }
    }

    private var isSending: Bool {
        switch mutationState {
        case .sending, .awaitingReconciliation: return true
        default: return false
        }
    }

    @ViewBuilder private var mutationCaption: some View {
        switch mutationState {
        case .idle: EmptyView()
        case .sending:
            Label(localizer.string("mobile.agentFeed.status.sending", defaultValue: "Sending…"), systemImage: "paperplane")
                .font(.caption)
                .accessibilityIdentifier("MobileAgentFeedSending-\(suffix)")
        case .awaitingReconciliation:
            Label(
                localizer.string("mobile.agentFeed.status.reconciling", defaultValue: "Sent. Waiting for agent."),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .accessibilityIdentifier("MobileAgentFeedReconciling-\(suffix)")
        case .failed:
            Label(localizer.string("mobile.agentFeed.status.failed", defaultValue: "Failed. Try again."), systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red)
                .accessibilityIdentifier("MobileAgentFeedFailed-\(suffix)")
        }
    }

    private var suffix: String { "\(item.macDeviceID)-\(item.wire.id.uuidString)" }

    private static func decodeBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return nil
        }
    }

    private func booleanLabel(_ label: String, value: Bool) -> String {
        guard label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return label }
        return value
            ? localizer.string("mobile.agentFeed.boolean.yes", defaultValue: "Yes")
            : localizer.string("mobile.agentFeed.boolean.no", defaultValue: "No")
    }

    private var disclosureAccessibilityLabel: String {
        [
            copy.sourceLabel(item.wire.source),
            copy.statusLabel(for: item, requiresResponse: requiresResponse),
            item.macDisplayName,
            item.connectionStatus.label,
            item.wire.workstreamID,
            copy.workspaceRouteLabel(item.wire.workspaceID),
            copy.surfaceRouteLabel(item.wire.surfaceID),
            item.wire.title,
            copy.payloadSummary(item.wire.payload),
            copy.resolutionLabel(
                item.wire.status,
                payload: item.wire.payload,
                source: item.wire.source
            ),
            completionAccessibilityText,
            item.wire.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
        ]
        .compactMap { $0 }
        .formatted()
    }

    private var completionAccessibilityText: String? {
        guard item.isTurnCompletion else { return nil }
        if let message = item.wire.lastAssistantMessage {
            return message
        }
        guard !interactionsEnabled else { return nil }
        return localizer.string(
            "mobile.agentFeed.card.noResponse",
            defaultValue: "No response. The agent stopped waiting."
        )
    }
}

private struct AgentFeedRowHeader: View {
    let item: MobileAgentFeedItem
    let design: MobileAgentFeedDesign
    let requiresResponse: Bool
    let localizer: AgentFeedLocalizer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var copy: AgentFeedRowCopy { AgentFeedRowCopy(localizer: localizer) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: requiresResponse ? "exclamationmark.bubble.fill" : "bubble.left.and.text.bubble.right")
                .font(design == .compact ? .caption : .body)
            VStack(alignment: .leading) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) {
                        sourceLabel
                        statusLabel
                    }
                } else {
                    HStack {
                        sourceLabel
                        statusLabel
                    }
                }
                Text(computerContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                if dynamicTypeSize.isAccessibilitySize { relativeTime }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize { relativeTime }
        }
    }

    private var sourceLabel: some View {
        Text(copy.sourceLabel(item.wire.source))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLabel: some View {
        Text(copy.statusLabel(for: item, requiresResponse: requiresResponse))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var computerContext: String {
        localizer.string(
            "mobile.agentFeed.card.computerContext",
            defaultValue: "\(item.macDisplayName) · \(item.connectionStatus.label) · \(item.wire.workstreamID)"
        )
    }

    private var relativeTime: some View {
        Text(item.wire.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentFeedContext: View {
    let item: MobileAgentFeedItem
    let isExpanded: Bool
    let requiresResponse: Bool
    let interactionsEnabled: Bool
    let localizer: AgentFeedLocalizer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var copy: AgentFeedRowCopy { AgentFeedRowCopy(localizer: localizer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = item.wire.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.isTurnCompletion,
               (!requiresResponse || !interactionsEnabled),
               item.wire.lastAssistantMessage == nil {
                Text(localizer.string(
                    "mobile.agentFeed.card.noResponse",
                    defaultValue: "No response. The agent stopped waiting."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(copy.payloadSummary(item.wire.payload))
                    .font(.subheadline)
                    .lineLimit(isExpanded || dynamicTypeSize.isAccessibilitySize ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resolution = copy.resolutionLabel(
                item.wire.status,
                payload: item.wire.payload,
                source: item.wire.source
            ) {
                Text(resolution)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            if item.isTurnCompletion,
               let lastAssistantMessage = item.wire.lastAssistantMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizer.string(
                        "mobile.agentFeed.card.lastResponse",
                        defaultValue: "Last response"
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Text(lastAssistantMessage)
                        .textSelection(.enabled)
                        .lineLimit(isExpanded || dynamicTypeSize.isAccessibilitySize ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isExpanded, let cwd = item.wire.cwd {
                Text(cwd)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentFeedRowCopy {
    let localizer: AgentFeedLocalizer
    func workspaceRouteLabel(_ workspaceID: String?) -> String {
        localizer.string(
            "mobile.agentFeed.card.workspaceID",
            defaultValue: "Workspace ID: \(routeValue(workspaceID))"
        )
    }

    func surfaceRouteLabel(_ surfaceID: String?) -> String {
        localizer.string(
            "mobile.agentFeed.card.surfaceID",
            defaultValue: "Surface ID: \(routeValue(surfaceID))"
        )
    }

    private func routeValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return localizer.string(
                "mobile.agentFeed.card.routeUnavailable",
                defaultValue: "Unavailable"
            )
        }
        return value
    }

    func statusLabel(_ status: MobileWorkstreamFeedStatus) -> String {
        switch status {
        case .pending: localizer.string("mobile.agentFeed.card.pending", defaultValue: "Needs input")
        case .resolved: localizer.string("mobile.agentFeed.card.resolved", defaultValue: "Resolved")
        case .expired: localizer.string("mobile.agentFeed.card.expired", defaultValue: "Expired")
        case .telemetry: localizer.string("mobile.agentFeed.card.activity", defaultValue: "Activity")
        case .unknown: localizer.string("mobile.agentFeed.card.unknown", defaultValue: "Unknown status")
        }
    }

    func statusLabel(for item: MobileAgentFeedItem, requiresResponse: Bool) -> String {
        requiresResponse
            ? localizer.string("mobile.agentFeed.card.pending", defaultValue: "Needs input")
            : statusLabel(item.wire.status)
    }

    func sourceLabel(_ source: String) -> String {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude": return localizer.string("mobile.agentFeed.source.claude", defaultValue: "Claude")
        case "codex": return localizer.string("mobile.agentFeed.source.codex", defaultValue: "Codex")
        case "opencode": return localizer.string("mobile.agentFeed.source.opencode", defaultValue: "OpenCode")
        case "hermes-agent": return localizer.string("mobile.agentFeed.source.hermes", defaultValue: "Hermes")
        case "gemini": return localizer.string("mobile.agentFeed.source.gemini", defaultValue: "Gemini")
        case "amp": return localizer.string("mobile.agentFeed.source.amp", defaultValue: "Amp")
        case "antigravity", "agy": return localizer.string("mobile.agentFeed.source.antigravity", defaultValue: "Antigravity")
        case "codebuddy": return localizer.string("mobile.agentFeed.source.codebuddy", defaultValue: "CodeBuddy")
        case "copilot": return localizer.string("mobile.agentFeed.source.copilot", defaultValue: "Copilot")
        case "cursor", "cursor-agent": return localizer.string("mobile.agentFeed.source.cursor", defaultValue: "Cursor")
        case "factory": return localizer.string("mobile.agentFeed.source.factory", defaultValue: "Factory")
        case "grok", "grok-code": return localizer.string("mobile.agentFeed.source.grok", defaultValue: "Grok")
        case "kimi": return localizer.string("mobile.agentFeed.source.kimi", defaultValue: "Kimi Code")
        case "kiro": return localizer.string("mobile.agentFeed.source.kiro", defaultValue: "Kiro")
        case "qoder": return localizer.string("mobile.agentFeed.source.qoder", defaultValue: "Qoder")
        case "rovodev", "rovo": return localizer.string("mobile.agentFeed.source.rovodev", defaultValue: "Rovo Dev")
        default:
            return localizer.string(
                "mobile.agentFeed.source.other",
                defaultValue: "Agent: \(source)"
            )
        }
    }

    func payloadSummary(_ payload: MobileWorkstreamFeedPayload) -> String {
        switch payload {
        case .permission(_, let tool, let summary, _): return summary.isEmpty ? tool : "\(tool)\n\(summary)"
        case .exitPlan(_, let plan, let summary, _): return summary ?? plan
        case .question(_, let questions): return questions.map(\.prompt).formatted()
        case .boolean(_, let prompt, let yesLabel, let noLabel, _):
            return "\(prompt) (\(yesLabel) / \(noLabel))"
        case .form(_, let title, let fields, _):
            return title ?? fields.map(\.prompt).formatted()
        case .toolUse(let name, _):
            return localizer.string("mobile.agentFeed.activity.toolUse", defaultValue: "Using \(name)")
        case .toolResult(let name, let result, let isError):
            return isError
                ? localizer.string(
                    "mobile.agentFeed.activity.toolErrorGeneric",
                    defaultValue: "\(name) failed"
                )
                : result
        case .message(let text, _): return text
        case .stop(let reason): return reason ?? localizer.string("mobile.agentFeed.activity.turnComplete", defaultValue: "Turn complete. Reply to continue.")
        case .todos: return localizer.string("mobile.agentFeed.activity.todos", defaultValue: "Task list updated")
        case .lifecycle: return localizer.string("mobile.agentFeed.activity.lifecycle", defaultValue: "Session activity")
        case .unknown: return localizer.string("mobile.agentFeed.activity.unknown", defaultValue: "Agent activity")
        }
    }

    func permissionModeLabel(_ mode: String, source: String? = nil) -> String {
        switch mode {
        case "once": localizer.string("mobile.agentFeed.permission.once", defaultValue: "Allow Once")
        case "always": source?.lowercased() == "codex"
            ? localizer.string("mobile.agentFeed.permission.session", defaultValue: "Allow for Session")
            : localizer.string("mobile.agentFeed.permission.always", defaultValue: "Always Allow")
        case "persistent": localizer.string("mobile.agentFeed.permission.persistent", defaultValue: "Always Allow")
        case "all": localizer.string("mobile.agentFeed.permission.all", defaultValue: "Allow All")
        case "bypass": localizer.string("mobile.agentFeed.permission.bypass", defaultValue: "Bypass")
        default: localizer.string("mobile.agentFeed.permission.deny", defaultValue: "Deny")
        }
    }

    func decisionLabel(
        _ decision: MobileWorkstreamDecision?,
        payload: MobileWorkstreamFeedPayload,
        source: String?
    ) -> String? {
        switch decision {
        case .permission(let mode): return permissionModeLabel(mode, source: source)
        case .exitPlan(let mode, let feedback):
            let label = planModeLabel(mode)
            if let feedback, !feedback.isEmpty { return "\(label): \(feedback)" }
            return label
        case .question(let selections):
            let answers = resolvedQuestionAnswers(selections, payload: payload)
            return answers.isEmpty ? nil : answers.formatted()
        case .form(let action, let selections):
            switch action {
            case "decline":
                return localizer.string("mobile.agentFeed.form.declined", defaultValue: "Declined")
            case "cancel":
                return localizer.string("mobile.agentFeed.form.cancelled", defaultValue: "Cancelled")
            default:
                let answers = resolvedQuestionAnswers(selections, payload: payload)
                return answers.isEmpty
                    ? localizer.string("mobile.agentFeed.form.accepted", defaultValue: "Accepted")
                    : answers.formatted()
            }
        case .unknown(let kind): return kind
        case nil: return nil
        }
    }

    func resolutionLabel(
        _ status: MobileWorkstreamFeedStatus,
        payload: MobileWorkstreamFeedPayload,
        source: String? = nil
    ) -> String? {
        switch status {
        case .resolved(let decision):
            if let answer = decisionLabel(decision, payload: payload, source: source) {
                return localizer.string(
                    "mobile.agentFeed.card.resolution",
                    defaultValue: "Resolved: \(answer)"
                )
            }
            return localizer.string(
                "mobile.agentFeed.card.resolved",
                defaultValue: "Resolved"
            )
        case .expired:
            return localizer.string(
                "mobile.agentFeed.card.noResponse",
                defaultValue: "No response. The agent stopped waiting."
            )
        default:
            return nil
        }
    }

    private func resolvedQuestionAnswers(
        _ selections: [String],
        payload: MobileWorkstreamFeedPayload
    ) -> [String] {
        selections.compactMap { selection in
            guard let separator = selection.firstIndex(of: "=") else {
                return selection.isEmpty ? nil : selection
            }
            let questionID = String(selection[..<separator])
            let rawValue = String(selection[selection.index(after: separator)...])
            switch payload {
            case .question(_, let questions), .form(_, _, let questions, _):
                guard let question = questions.first(where: { $0.id == questionID }) else {
                    return displayAnswer(rawValue, question: nil)
                }
                let answer = displayAnswer(rawValue, question: question)
                return question.prompt.isEmpty ? answer : "\(question.prompt): \(answer)"
            case .boolean(_, _, let yesLabel, let noLabel, _):
                switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "y", "on", "opt0": return yesLabel
                case "0", "false", "no", "n", "off", "opt1": return noLabel
                default: return rawValue
                }
            default:
                return rawValue
            }
        }
    }

    private func displayAnswer(
        _ rawValue: String,
        question: MobileWorkstreamQuestion?
    ) -> String {
        let normalizedInputType = question?.inputType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["secret", "password", "passphrase"].contains(normalizedInputType)
            || rawValue == "<provided>" {
            return localizer.string(
                "mobile.agentFeed.card.secretProvided",
                defaultValue: "Provided"
            )
        }
        let value = rawValue.hasPrefix("other:")
            ? String(rawValue.dropFirst("other:".count))
            : rawValue
        if let option = question?.options.first(where: { $0.id == value }) {
            return option.label
        }
        if normalizedInputType == "boolean" {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on":
                return localizer.string("mobile.agentFeed.boolean.yes", defaultValue: "Yes")
            case "0", "false", "no", "n", "off":
                return localizer.string("mobile.agentFeed.boolean.no", defaultValue: "No")
            default:
                break
            }
        }
        return value
    }

    func planModeLabel(_ mode: String) -> String {
        switch mode {
        case "ultraplan": localizer.string("mobile.agentFeed.plan.ultraplan", defaultValue: "Ultraplan")
        case "bypassPermissions": localizer.string("mobile.agentFeed.plan.bypass", defaultValue: "Bypass Permissions")
        case "autoAccept": localizer.string("mobile.agentFeed.plan.autoAccept", defaultValue: "Auto-Accept")
        case "manual": localizer.string("mobile.agentFeed.plan.manual", defaultValue: "Manual")
        default: localizer.string("mobile.agentFeed.plan.deny", defaultValue: "Deny")
        }
    }
}
#endif
