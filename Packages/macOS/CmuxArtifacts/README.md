# CmuxArtifacts

`CmuxArtifacts` is the local, durable artifact catalog used by the macOS app.
It is deliberately a catalog rather than a crawler: callers submit an explicit
capture request, the repository validates that request, and a bounded index is
persisted atomically. URL, text, HTML, and file-backed records share the same
identity, ownership, provenance, retention, search, and transfer contracts.

The app creates one `LocalArtifactRepository` at its composition root and injects
it into every workspace. A workspace model is only a main-actor projection; it
does not become a second durable store. Tests can inject an `InMemoryArtifactRepository`
or a temporary `LocalArtifactRepository` without launching AppKit.
