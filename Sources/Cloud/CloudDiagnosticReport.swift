import Foundation

/// A user-requested support report made only from the structured operation snapshots.
enum CloudDiagnosticReport {
    static func text(operations: [CloudOperationSnapshot], client: CloudTelemetryClient = .current()) -> String {
        let identity = "cmux \(client.version) (\(client.build))\nchannel=\(client.channel) revision=\(client.revision)\nmacOS=\(client.osVersion) architecture=\(client.architecture)"
        return ([identity] + operations.map(operationText)).joined(separator: "\n\n")
    }

    static func operationText(_ operation: CloudOperationSnapshot) -> String {
        var lines = [operation.operation.label, operation.reference,
                     "started=\(operation.startedAt.ISO8601Format()) outcome=\(operation.outcome?.rawValue ?? "running")"]
        if let failure = operation.failure { lines.append("\(failure.label) (\(failure.rawValue))") }
        lines.append(contentsOf: operation.steps.map { stepText($0) })
        return lines.joined(separator: "\n")
    }

    static func stepText(_ step: CloudOperationSnapshot.Step) -> String {
        var line = "\(step.phase.label): \(step.outcome?.rawValue ?? "running") span=\(step.id)"
        if let duration = step.durationMs { line += " duration_ms=\(duration)" }
        if let failure = step.failure { line += "\n\(failure.label) (\(failure.rawValue))" }
        return line
    }
}
