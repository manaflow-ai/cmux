# Recorded source uses

Leo-Ask-Trace: ask-bdba7066a6

`_acpmux/source_uses {sessionId, uri, revision?, cursor?, limit?}` reads the existing
session journal's `turn_sources` records. It returns `{sessionId, uri, uses,
nextCursor, scanned}`; each use contains `seq`, `at`, `turnId`, raw segment
`replyId`, `toolCallId`, `kind`, `uri`, and recorded `title`/`revision` when present.
A segment `replyId` is not a harness message ID. The native document host must
retain the originating session and recorded URI; page content cannot choose
another session. URI matching is exact and performs no filesystem resolution.

An explicit session is required. The existing connection authentication applies;
paired read-only devices may read. The carrier maps this to its existing
`agent-session-events` verb and enforces the grant's exact session IDs before
dispatch. The query cannot list sessions. A cursor is bound to the resolved
session and URI/revision selection and is not an access grant.

Pages contain at most 100 uses and 256 KiB. Each page visits at most 512 records
in the journal's existing kind index. `nextCursor` must be followed even when
`uses` is empty. It resumes within a source record when needed and excludes
newer appended records. A cold index may first rebuild its existing segment
copy; this runs on the blocking pool, never a runtime worker. No new database,
background timer or journal writer is introduced. Retention preserves source
records; deletion of the session deletes their authority too.

This prevents the class of false backlinks derived from answer links, search
results or raw tool output. Detectors are `source_uses_restart_and_mid_record_pagination_preserve_exact_edges`,
`source_uses_no_match_scan_and_response_bytes_are_bounded`, and
`source_uses_rpc_enforces_carrier_session_grants_and_authentication`.
The existing successful-read collector owns what becomes a `turn_sources` edge.

This is the reverse-query component for local document navigation. It does not
supply a hosted wiki document service, grant access across teams, or invent a
public backlink URL. The Sources owner integrates the document bridge and exact
reply reveal, then verifies the integrated head through cmux-ci.
