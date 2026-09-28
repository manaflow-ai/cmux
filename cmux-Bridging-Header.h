// Keep the canonical C header visible to the app target as well as the
// framework module. The ExternalHover declarations are part of cmux's pinned
// Ghostty fork; importing the module alone can leave Xcode's explicit Clang
// module cache with the older public surface during an incremental admission
// build.
#include "ghostty.h"
#import "Sources/TerminationWatchdogAtomic.h"
