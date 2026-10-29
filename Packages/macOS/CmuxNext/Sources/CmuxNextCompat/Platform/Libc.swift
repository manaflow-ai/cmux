// The C library under one import: a module that imports CmuxNextCompat sees Darwin, so its POSIX calls need no
// import of their own. This file is only the re-export: the system declarations are used as they are, with no
// wrapper.

@_exported public import Darwin
