import Testing

// These suites spawn real Process/Pipe pairs and share the process-global file
// descriptor table. Keep them under one serialized parent so Swift Testing does
// not run fd-closing regression cases concurrently with other pipe captures.
@Suite("RemoteSession process tests", .serialized)
struct RemoteSessionProcessTestIsolation {}
