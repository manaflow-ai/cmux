// Keep the canonical Ghostty declarations in scope for the local action
// decoding helpers below. The framework import in the bridging header does
// not make those C declarations visible while this header is parsed.
#ifndef CMUX_GHOSTTY_EXTERNAL_HOVER_BRIDGE_H
#define CMUX_GHOSTTY_EXTERNAL_HOVER_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "ghostty/include/ghostty.h"

typedef struct {
    uint64_t token_bits[4];
    bool active;
} cmux_external_link_hover_action_s;

static inline bool cmux_ghostty_action_is_external_link_hover(ghostty_action_s action) {
    // The fork appends this action after the stable selection-changed tag.
    return (int)action.tag == (int)GHOSTTY_ACTION_SELECTION_CHANGED + 1;
}

static inline cmux_external_link_hover_action_s cmux_ghostty_action_external_link_hover(
    ghostty_action_s action
) {
    cmux_external_link_hover_action_s result = {0};
    memcpy(&result, &action.action, sizeof(result));
    return result;
}

#endif
