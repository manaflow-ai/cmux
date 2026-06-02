/// One parsed page of a host's pull/merge request list response.
///
/// A page pairs the mapped ``HostedPullRequest`` values with the **raw** item count the
/// response carried before any were dropped for an unmapped state or missing fields.
/// Pagination decisions must use ``rawItemCount`` rather than `pullRequests.count`: a
/// full page that contains states a custom ``GitHostingResponseSpec/stateMap`` does not
/// cover would otherwise look short and stop the page walk before later pages are read.
public struct GitHostingPage: Sendable, Equatable {
    /// The pull requests on this page whose native state mapped onto a cmux state.
    public let pullRequests: [HostedPullRequest]

    /// The number of items the response held on this page before state/field filtering.
    ///
    /// Compare this against ``GitHostingRequestPlan/pageSize`` to decide whether a full
    /// page came back and the next page should be fetched.
    public let rawItemCount: Int

    /// Creates a page.
    ///
    /// - Parameters:
    ///   - pullRequests: The successfully mapped pull requests.
    ///   - rawItemCount: The unfiltered item count the response carried on this page.
    public init(pullRequests: [HostedPullRequest], rawItemCount: Int) {
        self.pullRequests = pullRequests
        self.rawItemCount = rawItemCount
    }
}
