/// Holds one process snapshot service's ``CmuxTopProcessEnrichmentMemo``
/// between its censuses; the service runs one enrichment at a time.
actor CmuxTopProcessEnrichmentMemoStore {
    private var memo = CmuxTopProcessEnrichmentMemo()

    /// The memo the last enrichment left.
    func current() -> CmuxTopProcessEnrichmentMemo { memo }

    /// Keeps `next`, the memo of the census just enriched.
    func replace(with next: CmuxTopProcessEnrichmentMemo) { memo = next }
}
