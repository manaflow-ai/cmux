import Foundation

/// Reconciles tmux list output with the durable registry by immutable binding.
struct LocalTmuxSessionReconciler {
    let identityResolver: LocalTmuxSessionIdentityResolver

    func managedRecords(
        records: [LocalTmuxSessionRecord],
        liveSessions: [LocalTmuxSessionListParser.SessionLine]
    ) throws -> [LocalTmuxSessionBinding: LocalTmuxSessionRecord] {
        var recordsByBinding: [LocalTmuxSessionBinding: LocalTmuxSessionRecord] = [:]
        var legacyRecordsByName: [String: LocalTmuxSessionRecord] = [:]
        for record in records {
            if let binding = record.tmuxBinding {
                recordsByBinding[binding] = record
            } else {
                legacyRecordsByName[record.name] = record
            }
        }

        var managed: [LocalTmuxSessionBinding: LocalTmuxSessionRecord] = [:]
        for session in liveSessions {
            guard let candidate = recordsByBinding[session.binding]
                    ?? legacyRecordsByName[session.name],
                  let record = try identityResolver.reconciledRecord(
                    candidate,
                    observed: .init(name: session.name, binding: session.binding)
                  ) else {
                continue
            }
            managed[session.binding] = record
        }
        return managed
    }
}
