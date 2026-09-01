# CmuxWorkspaceEnvironment

Pure Foundation parsing and reversible serialization for cmux workspace
environment editor text. The package has no AppKit or application-state
dependency, so its behavior can be tested independently:

    import CmuxWorkspaceEnvironment

    let parser = WorkspaceEnvironmentParser()
    let values = try parser.parse("\\#COMMENT=first\\nsecond")
    let text = parser.serialize(values)

WorkspaceEnvironmentDocument escapes backslashes, CR/LF, and a leading # in
keys. Empty values are valid (`NAME=`); keys that collide after boundary
trimming are rejected. Call WorkspaceEnvironmentDocument.sanitized(_:) at
application input boundaries before persisting or spawning terminals.
