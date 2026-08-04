struct SimulatorUIAutomationScreenHashPayload: Encodable {
    let `protocol`: String
    let elements: [SimulatorUIAutomationElement]
    let actions: [SimulatorUIAutomationActionHint]
    let isTruncated: Bool
    let truncatedFields: [SimulatorUIAutomationTruncatedField]
}
