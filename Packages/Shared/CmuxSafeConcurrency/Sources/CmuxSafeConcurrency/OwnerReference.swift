/// A child's non-owning reference back to the object that owns it, for an owner that a test, a teardown or a bug
/// can free first.
///
/// An owner holds its children and a child's back-pointer does not own its owner, as Chromium's back-pointers are
/// `raw_ptr` (base/memory/raw_ptr.h), never a `scoped_refptr` that would keep the owner alive in a cycle. Unlike
/// `unowned`, a read after the owner is gone does not trap: ``resolve(in:fileID:line:)`` reports the read site's first
/// miss of the launch as an ``Invariant/notFatalUntil(_:_:build:in:fileID:line:)`` failure and returns nil, and the
/// caller refuses or does nothing. An owner that structurally outlives the child keeps `unowned` with a `lifetime:`
/// reason in scripts/cmux-next/crash-allowlist.json instead.
///
/// ```swift
/// private let ownerReference: OwnerReference<Runtime>
/// private var runtime: Runtime? { ownerReference.resolve() }
/// func reload() {
///     guard let runtime else { return }   // reported once per launch by `resolve`
///     runtime.reload(id)
/// }
/// ```
public struct OwnerReference<Owner: AnyObject> {
    /// The first build in which a miss traps. Not scheduled: set it to a real build once the reports stay at zero
    /// for a release cycle.
    public static var fatalFromBuild: UInt64 { UInt64.max }

    /// The invariant a miss reports under (`"runtime-outlives-its-tabs"`); each read site is its own site.
    public let invariantID: StaticString
    private weak var owner: Owner?

    public init(_ owner: Owner, invariant id: StaticString) {
        self.owner = owner
        invariantID = id
    }

    /// The owner, or nil after reporting this site's first miss of the launch.
    public func resolve(in invariant: Invariant = .process, fileID: StaticString = #fileID, line: UInt = #line) -> Owner? {
        if let owner { return owner }
        Invariant.notFatalUntil(false, invariantID, build: Self.fatalFromBuild, in: invariant, fileID: fileID, line: line)
        return nil
    }
}

extension OwnerReference: Sendable where Owner: Sendable {}
