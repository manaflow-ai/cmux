public import CmuxNextWakeups
import Foundation

/// `jobs-list` (`long_jobs`, plans/cmux-next/long-jobs-DESIGN.md): the owner's running long jobs,
/// `{"jobs":[...]}`. The `jobs-changed` event on the subscribe stream carries the same list on every
/// change (at most 4 a second).
public struct JobsListRequest: DaemonRequest {
    public typealias Response = LongJobList

    public static let command = "jobs-list"
    public static var requiredCapability: String? { DaemonCapability.longJobs.rawValue }

    public init() {}
}
