# CmuxArtifacts

`CmuxArtifacts` owns cmux's local, project-scoped session filesystem.

Each agent session owns an ordinary directory under `<project>/.cmux/`, with
`artifacts/` and `notes/` as sibling content directories:

```text
<project>/.cmux/
  <agent-session>/
    _session.json
    _workspace.json
    artifacts/
    notes/
  .metadata/
    provenance/
    imports/
```

`LocalArtifactRepository` treats every live scan as authoritative. Users and
agents may rename or reorganize files and session folders with Finder or the
shell; small marker files let later writes rediscover a moved session without a
path index. `ArtifactCaptureService` applies conservative automatic-capture
limits before importing agent-created files. Content-addressed capture history
lives under `.cmux/.metadata/provenance/`, so file moves do not lose
deduplication or provenance.

App, CLI, and sidebar callers share `LocalArtifactRepository`; artifact callers
use `ArtifactStoring` and Note callers use `NoteStoring`. UI code must project
`ArtifactSnapshot` values into immutable rows instead of retaining the
repository below a list boundary. Prompt-ready references are stable
project-relative paths such as `.cmux/<agent-session>/notes/plan.md`.

Projects can override the conservative defaults with a partial
`.cmux/artifacts.json` file. Supported keys are `automaticCaptureEnabled`,
`captureCreatedAndAttached`, `captureReferencedEphemeral`, `maximumFileBytes`,
`maximumTextFileBytes`, `maximumTranscriptScanBytes`, `maximumFilesPerCapture`,
`deduplicationScanNodeLimit`,
`deduplicationHashByteLimit`, `contentSearchMaximumBytes`,
`contentSearchTotalMaximumBytes`, `maximumSearchResults`, `allowedExtensions`, and
`ephemeralPathPrefixes`; omitted keys inherit the defaults in
`ArtifactCaptureConfiguration`.
