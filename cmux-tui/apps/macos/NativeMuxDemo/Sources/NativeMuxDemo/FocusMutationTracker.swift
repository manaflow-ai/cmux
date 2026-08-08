import Foundation

/// Owns the active optimistic focus request and its rollback snapshot.
struct FocusMutationTracker {
  private var nextRequestID: UInt64 = 0
  private var active: (id: UInt64, workspaceID: String?, screenID: String?)?

  mutating func begin(workspaceID: String?, screenID: String?) -> UInt64 {
    nextRequestID &+= 1
    active = (nextRequestID, workspaceID, screenID)
    return nextRequestID
  }

  func owns(_ requestID: UInt64) -> Bool {
    active?.id == requestID
  }

  mutating func finish(_ requestID: UInt64) -> Bool {
    guard owns(requestID) else { return false }
    active = nil
    return true
  }

  mutating func rollback(
    _ requestID: UInt64
  ) -> (workspaceID: String?, screenID: String?)? {
    guard let active, active.id == requestID else { return nil }
    self.active = nil
    return (active.workspaceID, active.screenID)
  }
}
