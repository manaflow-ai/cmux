enum SurfaceResumeApprovalLookup<Value> {
    case pendingSigningSecret
    case resolved(Value)
}

extension SurfaceResumeApprovalLookup: Sendable where Value: Sendable {}
