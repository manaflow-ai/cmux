/// Who authorized a locked nested display title.
public enum NestedTitleAuthority: String, Codable, Sendable, Hashable, CaseIterable {
    /// End-user rename or explicit lock.
    case user
    /// Provider-native title policy marked authoritative.
    case providerNative = "provider_native"
    /// Host cmux surface policy.
    case hostSurfacePolicy = "host_surface_policy"
}
