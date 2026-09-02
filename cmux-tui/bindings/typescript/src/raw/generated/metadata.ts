/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR 3abe68cfbb73abb8aab5265d34cdafd7207a111cbe9e1923c8637f5376abb929. */


export const SDK_SCHEMA_VERSION = 2 as const;
export const MUX_PROTOCOL_VERSION = 12 as const;
export const SDK_IR_SHA256 = "3abe68cfbb73abb8aab5265d34cdafd7207a111cbe9e1923c8637f5376abb929" as const;
export const PROTOCOL = {
  "id_type": "uint64",
  "javascript_id_policy": "All protocol identifiers are uint64 JSON numbers. JavaScript and TypeScript SDKs must decode them losslessly as bigint (or validated decimal strings at their public boundary), and must not expose IEEE-754 number ids. Pairing request ids, revisions, timestamps, frame sequences, and reservation ids follow the same rule.",
  "name": "cmux-tui-mux",
  "version": 12
} as const;
export const PROFILES = {
  "control": {
    "description": "Base authenticated session-control commands available to ordinary SDK clients.",
    "inherits": []
  },
  "frontend": {
    "description": "Rendering, input, presentation, subscribe, and attach commands.",
    "inherits": [
      "control"
    ]
  },
  "local-admin": {
    "description": "Trusted local administration commands.",
    "inherits": [
      "control"
    ],
    "transport": "Unix-classified transport, including direct Unix and the current stdio relay"
  },
  "provider-authority": {
    "description": "Provider-owned workspace mutation commands.",
    "inherits": [
      "control"
    ],
    "requires_authority": true
  }
} as const;
export const COMMAND_METADATA = {
  "apply-layout": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "attach-surface": {
    "authority": "frontend",
    "since": 5,
    "capability": null,
    "fields": {
      "cols": {
        "since": null,
        "capability": "attach-initial-size"
      },
      "mode": {
        "since": 7,
        "capability": null
      },
      "rows": {
        "since": null,
        "capability": "attach-initial-size"
      }
    },
    "stream": {
      "event_names": [
        "browser-state",
        "colors-changed",
        "detached",
        "frame",
        "notification",
        "output",
        "overflow",
        "render-delta",
        "render-state",
        "resized",
        "scroll-changed",
        "vt-state"
      ],
      "kind": "attach",
      "mode_field": "mode",
      "modes": {
        "browser": [
          "browser-state",
          "frame",
          "notification",
          "scroll-changed",
          "overflow",
          "detached"
        ],
        "bytes": [
          "vt-state",
          "output",
          "resized",
          "colors-changed",
          "scroll-changed",
          "notification",
          "overflow",
          "detached"
        ],
        "render": [
          "render-state",
          "render-delta",
          "scroll-changed",
          "overflow",
          "detached"
        ]
      },
      "ordering": "Initial state precedes the command response. Later surface events preserve order. A resized replay replaces the previous byte mirror; overflow ends that surface stream.",
      "terminal_event": "detached"
    },
    "constraints": []
  },
  "browser-activate": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only."
    ]
  },
  "browser-back": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; queue acknowledgement is not page-load success."
    ]
  },
  "browser-forward": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; queue acknowledgement is not page-load success."
    ]
  },
  "browser-frame-presented": {
    "authority": "frontend",
    "since": 10,
    "capability": "browser-pointer-frame-guard-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "Acknowledges the exact rendered browser frame for this connection.",
      "Requires browser-pointer-frame-guard-v1."
    ]
  },
  "browser-insert-text": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only.",
      "The bounded disposable input queue drops newest input when full."
    ]
  },
  "browser-key": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only.",
      "The bounded disposable input queue drops newest input when full."
    ]
  },
  "browser-key-press": {
    "authority": "frontend",
    "since": 10,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only.",
      "One request preserves the atomic press sequence through the bounded input queue."
    ]
  },
  "browser-mouse": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; coordinates are CSS pixels.",
      "The bounded disposable input queue drops newest input when full."
    ]
  },
  "browser-mouse-guarded": {
    "authority": "frontend",
    "since": 10,
    "capability": "browser-pointer-frame-guard-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; coordinates are CSS pixels.",
      "The frame sequence must be the exact presented token for this connection.",
      "Requires browser-pointer-frame-guard-v1."
    ]
  },
  "browser-navigate": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Queue acknowledgement only; observe browser-state for outcome.",
      "Navigation is latest-wins."
    ]
  },
  "browser-reload": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; queue acknowledgement is not page-load success."
    ]
  },
  "browser-wheel": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; values are CSS pixels.",
      "The bounded disposable input queue drops newest input when full."
    ]
  },
  "browser-wheel-guarded": {
    "authority": "frontend",
    "since": 10,
    "capability": "browser-pointer-frame-guard-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "Browser surfaces only; values are CSS pixels.",
      "The frame sequence must be the exact presented token for this connection.",
      "Requires browser-pointer-frame-guard-v1."
    ]
  },
  "clear-history": {
    "authority": "control",
    "since": 9,
    "capability": "clear-history-v1",
    "fields": {
      "fallback_key": {
        "since": 9,
        "capability": "clear-history-key-v1"
      }
    },
    "stream": null,
    "constraints": [
      "PTY surfaces only.",
      "Failed responses classify error_delivery as known-not-delivered or ambiguous."
    ]
  },
  "clear-window-title": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "client-focus": {
    "authority": "control",
    "since": 12,
    "capability": "client-focus-v1",
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "close-pane": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "close-provider-managed-workspace": {
    "authority": "provider-authority",
    "since": 9,
    "capability": "provider-managed-workspace-authority-v2",
    "fields": {},
    "stream": null,
    "constraints": [
      "Call only after the external provider durably accepts the close."
    ]
  },
  "close-screen": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "close-surface": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "close-terminal": {
    "authority": "control",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "close-workspace": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {
      "expected_generation": {
        "since": 7,
        "capability": null
      },
      "expected_revision": {
        "since": 7,
        "capability": null
      },
      "key": {
        "since": 7,
        "capability": "workspace-registry-v1"
      },
      "mutation_id": {
        "since": 7,
        "capability": null
      },
      "origin": {
        "since": 7,
        "capability": null
      }
    },
    "stream": null,
    "constraints": [
      "Provider-managed workspaces reject this ordinary mutation."
    ]
  },
  "copy": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only."
    ]
  },
  "create-surface-with-receipt": {
    "authority": "control",
    "since": 10,
    "capability": "creation-receipts-v1",
    "fields": {
      "idempotency_key": {
        "since": null,
        "capability": "creation-attempt-keys-v1"
      }
    },
    "stream": null,
    "constraints": [
      "Repeating one origin and receipt with identical fields returns the original creation result.",
      "A new idempotency_key is valid only when durable creation resolution instructs retry_new_idempotency_key."
    ]
  },
  "create-terminal": {
    "authority": "control",
    "since": 7,
    "capability": "workspace-registry-v1",
    "fields": {
      "terminal_id": {
        "since": 9,
        "capability": null
      }
    },
    "stream": null,
    "constraints": []
  },
  "create-workspace": {
    "authority": "control",
    "since": 7,
    "capability": "workspace-registry-v1",
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "detach-attached-view": {
    "authority": "frontend",
    "since": 10,
    "capability": "view-attachment-detach-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "The command closes only the named view stream and releases its size contribution.",
      "A retired lease returns outcome:superseded."
    ]
  },
  "detach-client": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "export-layout": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "focus-direction": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "focus-pane": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "get-browser-provider": {
    "authority": "local-admin",
    "since": 10,
    "capability": "browser-provider-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "Provider endpoints and targets are disclosed only over a trusted local transport; bearer credentials are accepted only during registration and are never returned.",
      "Automation must select a target by stable tab id instead of treating CDP discovery as topology authority."
    ]
  },
  "get-cell-pixels": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "get-frontend-projection": {
    "authority": "control",
    "since": 7,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Each identifier is nonempty, contains no control character, and is at most 128 bytes."
    ]
  },
  "identify": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "ids": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Short ids are snapshot-local labels; command parameters accept numeric ids only."
    ]
  },
  "journal-frontend-event": {
    "authority": "control",
    "since": 10,
    "capability": "frontend-journal-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "The server derives producer identity from the authenticated control client."
    ]
  },
  "list-agents": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "list-clients": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "list-terminals": {
    "authority": "control",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "list-workspaces": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "machine-usage": {
    "authority": "control",
    "since": 12,
    "capability": "machine-usage-v1",
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "mark-workspaces-provider-managed": {
    "authority": "provider-authority",
    "since": 9,
    "capability": "provider-managed-workspace-authority-v2",
    "fields": {},
    "stream": null,
    "constraints": [
      "Authority must match the value provisioned before this mux generation accepted control clients."
    ]
  },
  "mint-terminal-renderer": {
    "authority": "frontend",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Only terminal-host-backed PTYs can mint one-use renderer credentials."
    ]
  },
  "mint-terminal-renderer-by-terminal": {
    "authority": "frontend",
    "since": 11,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "The terminal resource ID is resolved atomically to the live terminal-host-backed PTY before minting a one-use renderer credential."
    ]
  },
  "move-tab": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "An out-of-range index clamps to the destination end."
    ]
  },
  "move-terminal": {
    "authority": "control",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "A move to the current workspace still commits a terminal revision with changed:false."
    ]
  },
  "move-workspace": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {
      "expected_generation": {
        "since": 7,
        "capability": null
      },
      "expected_revision": {
        "since": 7,
        "capability": null
      },
      "key": {
        "since": 7,
        "capability": "workspace-registry-v1"
      },
      "mutation_id": {
        "since": 7,
        "capability": null
      },
      "origin": {
        "since": 7,
        "capability": null
      }
    },
    "stream": null,
    "constraints": []
  },
  "new-browser-tab": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Bootstrap and navigation failures are asynchronous browser-state outcomes."
    ]
  },
  "new-pane": {
    "authority": "control",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "new-pane-right": {
    "authority": "control",
    "since": 9,
    "capability": "viewport-splits-v1",
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "new-screen": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "new-tab": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "new-workspace": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "notify": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "pairing-response": {
    "authority": "local-admin",
    "since": 7,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "The request id must identify a live, unexpired pairing challenge."
    ]
  },
  "pane-neighbor": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "ping": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "process-info": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only."
    ]
  },
  "put-frontend-projection": {
    "authority": "control",
    "since": 7,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "read-screen": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only."
    ]
  },
  "read-scrollback": {
    "authority": "control",
    "since": 7,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only; row indexes are snapshot-relative and not durable."
    ]
  },
  "register-browser-provider": {
    "authority": "local-admin",
    "since": 10,
    "capability": "browser-provider-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "The lease is scoped to the trusted local control connection and is released on disconnect.",
      "The endpoint must be an explicit loopback ws URL with no credentials or fragment.",
      "Bearer authentication is optional and sends the token only in the CDP WebSocket upgrade Authorization header.",
      "Each registration replaces that connection's complete target set; target ids are never journaled."
    ]
  },
  "release-attached-view-size": {
    "authority": "frontend",
    "since": 10,
    "capability": "view-attachment-lease-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "The attach stream remains live for cached rendering."
    ]
  },
  "release-surface-size": {
    "authority": "control",
    "since": 7,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "An absent lease is a successful no-op."
    ]
  },
  "reload-config": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "rename-pane": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "An empty name clears the pane name."
    ]
  },
  "rename-provider-managed-workspace": {
    "authority": "provider-authority",
    "since": 9,
    "capability": "provider-managed-workspace-authority-v2",
    "fields": {},
    "stream": null,
    "constraints": [
      "Call only after the external provider durably accepts the rename."
    ]
  },
  "rename-screen": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "An empty name clears the screen name."
    ]
  },
  "rename-surface": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "An empty name clears the surface name."
    ]
  },
  "rename-workspace": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {
      "expected_generation": {
        "since": 7,
        "capability": null
      },
      "expected_revision": {
        "since": 7,
        "capability": null
      },
      "key": {
        "since": 7,
        "capability": "workspace-registry-v1"
      },
      "mutation_id": {
        "since": 7,
        "capability": null
      },
      "origin": {
        "since": 7,
        "capability": null
      }
    },
    "stream": null,
    "constraints": [
      "Provider-managed workspaces reject this ordinary mutation."
    ]
  },
  "report-agent": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "A stored hook report outranks later socket reports until another hook report or surface close."
    ]
  },
  "report-focus": {
    "authority": "control",
    "since": 12,
    "capability": "client-focus-v1",
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "resize-attached-view": {
    "authority": "frontend",
    "since": 10,
    "capability": "view-attachment-lease-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "The lease must belong to this connection and surface.",
      "A retired lease returns outcome:superseded without changing replacement views."
    ]
  },
  "resize-surface": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "resolve-terminal": {
    "authority": "control",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "run": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {
      "key": {
        "since": 9,
        "capability": null
      }
    },
    "stream": null,
    "constraints": []
  },
  "scroll-surface": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only; negative values scroll up."
    ]
  },
  "select-screen": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "select-tab": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "select-workspace": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "send": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {
      "paste": {
        "since": 7,
        "capability": null
      }
    },
    "stream": null,
    "constraints": []
  },
  "send-key": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only."
    ]
  },
  "set-cell-pixels": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Accepted browser resizes complete asynchronously."
    ]
  },
  "set-client-info": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "set-client-sizing": {
    "authority": "control",
    "since": 10,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "set-default-colors": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {
      "complete": {
        "since": 9,
        "capability": null
      },
      "cursor": {
        "since": 9,
        "capability": null
      },
      "cursor_blink": {
        "since": 9,
        "capability": null
      },
      "cursor_style": {
        "since": 9,
        "capability": null
      },
      "palette": {
        "since": 9,
        "capability": null
      },
      "selection_bg": {
        "since": 9,
        "capability": null
      },
      "selection_fg": {
        "since": 9,
        "capability": null
      }
    },
    "stream": null,
    "constraints": [
      "Color strings are exactly #rrggbb.",
      "With complete:true, absent optional values reset to built-in defaults."
    ]
  },
  "set-ratio": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "set-split-ratio": {
    "authority": "control",
    "since": 8,
    "capability": null,
    "fields": {
      "transaction": {
        "since": 9,
        "capability": "layout-undo-v1"
      }
    },
    "stream": null,
    "constraints": []
  },
  "set-viewport-pane-width": {
    "authority": "control",
    "since": 9,
    "capability": "viewport-column-resize-v1",
    "fields": {
      "transaction": {
        "since": 9,
        "capability": "layout-undo-v1"
      }
    },
    "stream": null,
    "constraints": [
      "width must be finite."
    ]
  },
  "set-window-title": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "shutdown-daemon": {
    "authority": "local-admin",
    "since": 9,
    "capability": null,
    "fields": {
      "force": {
        "since": 10,
        "capability": "daemon-handoff-force-v1"
      }
    },
    "stream": null,
    "constraints": [
      "pid and generation must match the latest identify result.",
      "force bypasses native-browser ownership only; the identity fence and trusted-local authority still apply.",
      "Clients must require daemon-handoff-force-v1 before sending force:true.",
      "The daemon exits only after the success response is queued."
    ]
  },
  "sidebar-plugin": {
    "authority": "frontend",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "split": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "subscribe": {
    "authority": "frontend",
    "since": 5,
    "capability": null,
    "fields": {
      "surface": {
        "since": 9,
        "capability": "surface-subscribe-filter"
      },
      "tree_events": {
        "since": 7,
        "capability": null
      }
    },
    "stream": {
      "event_names": [
        "agent-changed",
        "bell",
        "client-attached",
        "client-changed",
        "client-detached",
        "client-list-invalidated",
        "config-reload-requested",
        "empty",
        "frontend-projection-changed",
        "layout-changed",
        "notification",
        "overflow",
        "pairing-requested",
        "pairing-resolved",
        "pane-added",
        "pane-closed",
        "screen-added",
        "screen-closed",
        "screen-renamed",
        "scroll-changed",
        "status",
        "surface-exited",
        "surface-output",
        "surface-resize-failed",
        "surface-resized",
        "tab-added",
        "tab-closed",
        "tab-renamed",
        "terminal-registry-changed",
        "title-changed",
        "tree-changed",
        "window-title-requested",
        "workspace-added",
        "workspace-closed",
        "workspace-moved",
        "workspace-renamed"
      ],
      "kind": "subscribe",
      "mode_field": "tree_events",
      "modes": {
        "coarse": [
          "tree-changed"
        ],
        "deltas": [
          "workspace-added",
          "workspace-closed",
          "workspace-renamed",
          "workspace-moved",
          "screen-added",
          "screen-closed",
          "screen-renamed",
          "pane-added",
          "pane-closed",
          "tab-added",
          "tab-closed",
          "tab-renamed",
          "tree-changed"
        ]
      },
      "ordering": "Response and event objects may interleave. Events preserve enqueue order per subscription. Delta workspace revisions are serialized in durable commit order; overflow ends the stream and requires resubscribe plus snapshot.",
      "terminal_event": null
    },
    "constraints": [
      "subscribe sends no initial tree snapshot.",
      "surface filtering occurs before the bounded mailbox."
    ]
  },
  "swap-pane": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  },
  "terminal-events": {
    "authority": "control",
    "since": 9,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Consumers apply only contiguous revisions for one registry_id and generation."
    ]
  },
  "undo-layout": {
    "authority": "control",
    "since": 9,
    "capability": "layout-undo-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "Clients must reject incomplete or contradictory result variants."
    ]
  },
  "unregister-browser-provider": {
    "authority": "local-admin",
    "since": 10,
    "capability": "browser-provider-v1",
    "fields": {},
    "stream": null,
    "constraints": [
      "Only the calling connection's provider lease is removed."
    ]
  },
  "vt-state": {
    "authority": "control",
    "since": 5,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "PTY surfaces only."
    ]
  },
  "wait-for": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": [
      "Blocks subsequent requests on this connection; SDKs should use a dedicated connection."
    ]
  },
  "zoom-pane": {
    "authority": "control",
    "since": 6,
    "capability": null,
    "fields": {},
    "stream": null,
    "constraints": []
  }
} as const;
export const EVENT_METADATA = {
  "agent-changed": {
    "since": 11,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "bell": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "browser-state": {
    "since": 6,
    "capability": null,
    "streams": [
      "attach-browser"
    ],
    "emission": "emitted"
  },
  "client-attached": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "client-changed": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "client-detached": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "client-list-invalidated": {
    "since": 9,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "serialized-never-emitted"
  },
  "colors-changed": {
    "since": 6,
    "capability": null,
    "streams": [
      "attach-byte"
    ],
    "emission": "emitted"
  },
  "config-reload-requested": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "detached": {
    "since": 5,
    "capability": null,
    "streams": [
      "attach-byte",
      "attach-render",
      "attach-browser"
    ],
    "emission": "emitted"
  },
  "empty": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "frame": {
    "since": 6,
    "capability": null,
    "streams": [
      "attach-browser"
    ],
    "emission": "emitted"
  },
  "frontend-projection-changed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "graphics-status": {
    "since": 10,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "layout-changed": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "machine-usage-changed": {
    "since": 12,
    "capability": "machine-usage-v1",
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "notification": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe",
      "attach-byte",
      "attach-browser"
    ],
    "emission": "emitted"
  },
  "output": {
    "since": 5,
    "capability": null,
    "streams": [
      "attach-byte"
    ],
    "emission": "emitted"
  },
  "overflow": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe",
      "attach-byte",
      "attach-render",
      "attach-browser"
    ],
    "emission": "emitted"
  },
  "pairing-requested": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "pairing-resolved": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "pane-added": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "pane-closed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "render-delta": {
    "since": 7,
    "capability": null,
    "streams": [
      "attach-render"
    ],
    "emission": "emitted"
  },
  "render-state": {
    "since": 7,
    "capability": null,
    "streams": [
      "attach-render"
    ],
    "emission": "emitted"
  },
  "resized": {
    "since": 6,
    "capability": null,
    "streams": [
      "attach-byte"
    ],
    "emission": "emitted"
  },
  "screen-added": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "screen-closed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "screen-renamed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "scroll-changed": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe",
      "attach-byte",
      "attach-render",
      "attach-browser"
    ],
    "emission": "emitted"
  },
  "status": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "surface-exited": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "surface-output": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "surface-resize-failed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "surface-resized": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "tab-added": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "tab-closed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "tab-renamed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "terminal-registry-changed": {
    "since": 9,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "title-changed": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "tree-changed": {
    "since": 5,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "vt-state": {
    "since": 5,
    "capability": null,
    "streams": [
      "attach-byte"
    ],
    "emission": "emitted"
  },
  "window-title-requested": {
    "since": 6,
    "capability": null,
    "streams": [
      "subscribe"
    ],
    "emission": "emitted"
  },
  "workspace-added": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "workspace-closed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "workspace-moved": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  },
  "workspace-renamed": {
    "since": 7,
    "capability": null,
    "streams": [
      "subscribe-deltas"
    ],
    "emission": "emitted"
  }
} as const;
export type TypeSchema = Readonly<Record<string, unknown>>;
export interface CommandSchema {
  readonly request: TypeSchema;
  readonly result: TypeSchema;
}
export const TYPE_SCHEMAS: Readonly<Record<string, TypeSchema>> = {
  "AgentRecord": {
    "additional_properties": false,
    "fields": {
      "session": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "source": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "AgentSource"
        }
      },
      "state": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "AgentState"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "updated_at_ms": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "AgentReportSource": {
    "kind": "enum",
    "values": [
      "socket",
      "hook"
    ]
  },
  "AgentSource": {
    "kind": "enum",
    "values": [
      "detected",
      "socket",
      "hook"
    ]
  },
  "AgentState": {
    "kind": "enum",
    "values": [
      "working",
      "blocked",
      "idle",
      "done",
      "unknown"
    ]
  },
  "AppliedPane": {
    "additional_properties": false,
    "fields": {
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "ApplyLayoutResult": {
    "additional_properties": false,
    "fields": {
      "panes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "AppliedPane"
          },
          "kind": "array"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "AttachedViewOutcomeResult": {
    "additional_properties": false,
    "fields": {
      "outcome": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ViewAttachmentOutcome"
        }
      }
    },
    "kind": "object"
  },
  "AttachedViewResizeResult": {
    "additional_properties": false,
    "fields": {
      "accepted": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "outcome": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ViewAttachmentOutcome"
        }
      },
      "reservation_id": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "Base64": {
    "kind": "alias",
    "target": {
      "kind": "scalar",
      "name": "string"
    }
  },
  "BrowserFrame": {
    "additional_properties": false,
    "fields": {
      "data": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "height": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "seq": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "width": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "BrowserProviderAuthentication": {
    "kind": "enum",
    "values": [
      "none",
      "bearer"
    ]
  },
  "BrowserProviderSnapshot": {
    "additional_properties": false,
    "constraints": [
      "available is true exactly when provider_id, endpoint, authentication, and clients are present.",
      "Provider bearer tokens are accepted only during registration and are never returned."
    ],
    "fields": {
      "authentication": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "BrowserProviderAuthentication"
        }
      },
      "available": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "clients": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "endpoint": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "provider_id": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "targets": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "BrowserProviderTarget"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "BrowserProviderTarget": {
    "additional_properties": false,
    "fields": {
      "tab_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "target_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "BrowserProviderUnregisterResult": {
    "additional_properties": false,
    "fields": {
      "removed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      }
    },
    "kind": "object"
  },
  "CellPixelFailure": {
    "additional_properties": false,
    "fields": {
      "error": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "CellPixelResize": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "reservation_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "CellPixelSurface": {
    "additional_properties": false,
    "fields": {
      "height_px": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "width_px": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      }
    },
    "kind": "object"
  },
  "ClientInfo": {
    "additional_properties": false,
    "fields": {
      "attached": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Id"
          },
          "kind": "array"
        }
      },
      "client": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "connected_seconds": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "kind": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "name": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "self": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "sizes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "ClientSize"
          },
          "kind": "array"
        }
      },
      "transport": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ClientTransport"
        }
      }
    },
    "kind": "object"
  },
  "ClientSize": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "rows": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "size_participating": {
        "nullable": false,
        "presence": "required",
        "since": 10,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "ClientTransport": {
    "kind": "enum",
    "values": [
      "local",
      "unix",
      "ws"
    ]
  },
  "CloseTerminalResult": {
    "additional_properties": false,
    "fields": {
      "already_closed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "closed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "ColorHex": {
    "kind": "alias",
    "target": {
      "kind": "scalar",
      "name": "string"
    }
  },
  "CopyResult": {
    "additional_properties": false,
    "fields": {
      "mode": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "screen",
            "selection",
            "scrollback"
          ]
        }
      },
      "text": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "CursorStyle": {
    "kind": "enum",
    "values": [
      "block",
      "underline",
      "bar"
    ]
  },
  "DeadPane": {
    "additional_properties": false,
    "fields": {
      "dead": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      },
      "id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "DeclarativeLayout": {
    "kind": "tagged_union",
    "tag": "type",
    "variants": {
      "leaf": {
        "additional_properties": false,
        "fields": {
          "command": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "items": {
                "kind": "scalar",
                "name": "string"
              },
              "kind": "array",
              "min_items": 1
            }
          },
          "cwd": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "type": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "leaf"
            }
          }
        },
        "kind": "object"
      },
      "split": {
        "additional_properties": false,
        "fields": {
          "a": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "DeclarativeLayout"
            }
          },
          "b": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "DeclarativeLayout"
            }
          },
          "dir": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "SplitDirection"
            }
          },
          "ratio": {
            "constraints": [
              {
                "clamped_maximum": 0.95,
                "clamped_minimum": 0.05
              }
            ],
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "float32"
            }
          },
          "type": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "split"
            }
          }
        },
        "kind": "object"
      },
      "stack": {
        "additional_properties": false,
        "fields": {
          "expanded": {
            "constraints": [
              "Must identify a member of panes."
            ],
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "Id"
            }
          },
          "panes": {
            "nullable": false,
            "presence": "required",
            "type": {
              "items": {
                "kind": "ref",
                "name": "Id"
              },
              "kind": "array",
              "min_items": 1
            }
          },
          "type": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "stack"
            }
          }
        },
        "kind": "object"
      }
    }
  },
  "EmptyResult": {
    "additional_properties": false,
    "fields": {},
    "kind": "object"
  },
  "ExportLayoutResult": {
    "additional_properties": false,
    "fields": {
      "layout": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Layout"
        }
      },
      "panes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "ExportedPane"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "ExportedPane": {
    "additional_properties": false,
    "fields": {
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surfaces": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Id"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "FocusDirectionResult": {
    "additional_properties": false,
    "fields": {
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "FrontendFocusTarget": {
    "kind": "enum",
    "values": [
      "pane",
      "machine_rail",
      "workspace_rail",
      "tabs_rail",
      "projection_rail"
    ]
  },
  "FrontendJournalEvent": {
    "kind": "tagged_union",
    "tag": "kind",
    "variants": {
      "focus": {
        "additional_properties": false,
        "fields": {
          "content_id": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "event_id": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "frontend_projection_id": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "generation": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "kind": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "focus"
            }
          },
          "pane_id": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "screen_id": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "tab_id": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "target": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "FrontendFocusTarget"
            }
          },
          "workspace_id": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          }
        },
        "kind": "object"
      },
      "resize": {
        "additional_properties": false,
        "fields": {
          "cell_height": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "uint16"
            }
          },
          "cell_width": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "uint16"
            }
          },
          "cols": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "uint16"
            }
          },
          "event_id": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "frontend_projection_id": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "generation": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "kind": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "resize"
            }
          },
          "rows": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "uint16"
            }
          }
        },
        "kind": "object"
      },
      "viewport": {
        "additional_properties": false,
        "fields": {
          "event_id": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "frontend_projection_id": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "generation": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "kind": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "viewport"
            }
          },
          "offset": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "uint64"
            }
          },
          "screen_id": {
            "default": null,
            "nullable": true,
            "presence": "optional",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          },
          "settled": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "boolean"
            }
          },
          "target": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "uint64"
            }
          }
        },
        "kind": "object"
      }
    }
  },
  "FrontendProjection": {
    "additional_properties": false,
    "fields": {
      "frontend": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "projection": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "JsonValue"
        }
      },
      "projection_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "replayed": {
        "default": false,
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "schema_version": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "scope": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "subject_key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "GetCellPixelsResult": {
    "additional_properties": false,
    "fields": {
      "height_px": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surfaces": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "CellPixelSurface"
          },
          "kind": "array"
        }
      },
      "width_px": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      }
    },
    "kind": "object"
  },
  "Id": {
    "kind": "alias",
    "target": {
      "kind": "scalar",
      "name": "uint64"
    }
  },
  "IdMapping": {
    "additional_properties": false,
    "fields": {
      "id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "kind": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "workspace",
            "screen",
            "pane",
            "surface"
          ]
        }
      },
      "short_id": {
        "constraints": [
          {
            "pattern": "^[a-z0-9]{6}$"
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "IdentifyResult": {
    "additional_properties": false,
    "fields": {
      "app": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "cmux-tui"
        }
      },
      "build_commit": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "capabilities": {
        "default": [],
        "nullable": false,
        "presence": "optional",
        "type": {
          "items": {
            "kind": "scalar",
            "name": "string"
          },
          "kind": "array"
        }
      },
      "daemon_handoff": {
        "nullable": false,
        "presence": "required",
        "since": 9,
        "type": {
          "kind": "literal",
          "value": 1
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "ghostty_commit": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "lifecycle_ready": {
        "default": true,
        "nullable": false,
        "presence": "optional",
        "since": 12,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "pid": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "protocol": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "session": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "version": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "IdsResult": {
    "additional_properties": false,
    "fields": {
      "ids": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "IdMapping"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "JsonValue": {
    "kind": "opaque_json",
    "reason": "The wire field intentionally carries a frontend-authored or runtime-authored arbitrary JSON document."
  },
  "KittyGraphicsState": {
    "additional_properties": false,
    "fields": {
      "alternate_next_image_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "alternate_replay_next_image_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "image_bytes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "images": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "inflight_bytes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "placements": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "primary_next_image_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "primary_replay_next_image_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "replay_cursor_offset": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "KittyImageAlias": {
    "additional_properties": false,
    "fields": {
      "image_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "image_number": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "Layout": {
    "kind": "tagged_union",
    "tag": "type",
    "variants": {
      "leaf": {
        "additional_properties": false,
        "fields": {
          "pane": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "Id"
            }
          },
          "type": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "leaf"
            }
          }
        },
        "kind": "object"
      },
      "split": {
        "additional_properties": false,
        "fields": {
          "a": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "Layout"
            }
          },
          "b": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "Layout"
            }
          },
          "dir": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "SplitDirection"
            }
          },
          "ratio": {
            "constraints": [
              {
                "maximum": 0.95,
                "minimum": 0.05
              }
            ],
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "float32"
            }
          },
          "split": {
            "description": "Stable for the lifetime of this split node.",
            "nullable": false,
            "presence": "optional",
            "since": 8,
            "type": {
              "kind": "ref",
              "name": "Id"
            }
          },
          "type": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "split"
            }
          }
        },
        "kind": "object"
      },
      "stack": {
        "additional_properties": false,
        "fields": {
          "expanded": {
            "constraints": [
              "Must identify a member of panes."
            ],
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "ref",
              "name": "Id"
            }
          },
          "panes": {
            "nullable": false,
            "presence": "required",
            "type": {
              "items": {
                "kind": "ref",
                "name": "Id"
              },
              "kind": "array",
              "min_items": 1
            }
          },
          "type": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "stack"
            }
          }
        },
        "kind": "object"
      }
    }
  },
  "LayoutUndoConfirmationRequired": {
    "additional_properties": false,
    "fields": {
      "closes_panes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Id"
          },
          "kind": "array"
        }
      },
      "confirmation_required": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      },
      "revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "undone": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": false
        }
      }
    },
    "kind": "object"
  },
  "LayoutUndoResult": {
    "kind": "untagged_union",
    "variants": [
      {
        "kind": "ref",
        "name": "LayoutUndoUndone"
      },
      {
        "kind": "ref",
        "name": "LayoutUndoConfirmationRequired"
      }
    ]
  },
  "LayoutUndoUndone": {
    "additional_properties": false,
    "fields": {
      "confirmation_required": {
        "default": false,
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "literal",
          "value": false
        }
      },
      "revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "undone": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      }
    },
    "kind": "object"
  },
  "ListAgentsResult": {
    "additional_properties": false,
    "fields": {
      "agents": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "AgentRecord"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "ListTerminalsResult": {
    "additional_properties": false,
    "fields": {
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "terminals": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "TerminalRecord"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "LivePane": {
    "additional_properties": false,
    "fields": {
      "active_tab": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "focused_at": {
        "default": 0,
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "name": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "short_id": {
        "constraints": [
          {
            "pattern": "^[a-z0-9]{6}$"
          }
        ],
        "nullable": false,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "tabs": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Tab"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "MachineUsage": {
    "additional_properties": false,
    "constraints": [
      "period_days is the trailing window length in days.",
      "api_equivalent_usd is the list-price equivalent of the machine's model traffic in that window."
    ],
    "fields": {
      "api_equivalent_usd": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "float64"
        }
      },
      "as_of": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "period_days": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "total_tokens": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "vm_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "MachineUsageResult": {
    "additional_properties": false,
    "constraints": [
      "usage is null when the daemon has no readout (not a Cloud VM, endpoint unavailable, or usage not ready)."
    ],
    "fields": {
      "usage": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "MachineUsage"
        }
      }
    },
    "kind": "object"
  },
  "MintTerminalRendererResult": {
    "additional_properties": false,
    "fields": {
      "endpoint": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "incarnation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "protocol_version": {
        "nullable": false,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "rights": {
        "constraints": [
          {
            "current_value": 7
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "token": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "ttl_ms": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "MoveTerminalResult": {
    "additional_properties": false,
    "fields": {
      "changed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "lifecycle": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalLifecycle"
        }
      },
      "pane": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "replayed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "screen": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspace": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "NotificationLevel": {
    "kind": "enum",
    "values": [
      "info",
      "warning",
      "error"
    ]
  },
  "NotificationMarker": {
    "additional_properties": false,
    "fields": {
      "level": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "NotificationLevel"
        }
      },
      "notification": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "unread": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      }
    },
    "kind": "object"
  },
  "NotifyResult": {
    "additional_properties": false,
    "fields": {
      "notification": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "Pane": {
    "kind": "untagged_union",
    "variants": [
      {
        "kind": "ref",
        "name": "LivePane"
      },
      {
        "kind": "ref",
        "name": "DeadPane"
      }
    ]
  },
  "PaneDirection": {
    "kind": "enum",
    "values": [
      "left",
      "right",
      "up",
      "down"
    ]
  },
  "PaneNeighborResult": {
    "additional_properties": false,
    "fields": {
      "pane": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "PingResult": {
    "additional_properties": false,
    "fields": {
      "build_commit": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "ghostty_commit": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "ok": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      },
      "protocol": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "version": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "ProcessInfoResult": {
    "additional_properties": false,
    "fields": {
      "command": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "cwd": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "foreground_cwd": {
        "description": "Working directory of the process group that owns the PTY, read at request time. Null when the lookup fails; absent from daemons that predate the field. Clients treat absence as null.",
        "nullable": true,
        "presence": "optional",
        "since": 12,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "pid": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "ProviderWorkspaceMutationResult": {
    "additional_properties": false,
    "fields": {
      "key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "ReadScreenResult": {
    "additional_properties": false,
    "fields": {
      "text": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "ReadScrollbackResult": {
    "additional_properties": false,
    "fields": {
      "epoch": {
        "nullable": false,
        "presence": "required",
        "since": 10,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderRow"
          },
          "kind": "array"
        }
      },
      "start": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "total": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "RenderCursor": {
    "additional_properties": false,
    "fields": {
      "blink": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "color": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "style": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "CursorStyle"
        }
      },
      "visible": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "x": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "y": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      }
    },
    "kind": "object"
  },
  "RenderGraphicFormat": {
    "kind": "enum",
    "values": [
      "rgb",
      "rgba"
    ]
  },
  "RenderGraphicImage": {
    "additional_properties": false,
    "fields": {
      "data": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "format": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "RenderGraphicFormat"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "height": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "width": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "RenderGraphicPlacement": {
    "additional_properties": false,
    "fields": {
      "anchor_col": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "anchor_row": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "columns": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "grid_cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "grid_rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "image_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "ordinal": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "pixel_height": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "pixel_width": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "placement_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "source_height": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "source_width": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "source_x": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "source_y": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "viewport_col": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "int32"
        }
      },
      "viewport_row": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "int32"
        }
      },
      "viewport_visible": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "x_offset": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "y_offset": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "z": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "int32"
        }
      }
    },
    "kind": "object"
  },
  "RenderGraphics": {
    "additional_properties": false,
    "fields": {
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "images": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderGraphicImage"
          },
          "kind": "array"
        }
      },
      "placements": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderGraphicPlacement"
          },
          "kind": "array"
        }
      },
      "removed_image_ids": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "items": {
            "kind": "scalar",
            "name": "uint32"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "RenderGraphicsDelta": {
    "additional_properties": false,
    "fields": {
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "images": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderGraphicImage"
          },
          "kind": "array"
        }
      },
      "placements": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderGraphicPlacement"
          },
          "kind": "array"
        }
      },
      "removed_image_ids": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "items": {
            "kind": "scalar",
            "name": "uint32"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "RenderRow": {
    "additional_properties": false,
    "fields": {
      "row": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "runs": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderRun"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "RenderRun": {
    "additional_properties": false,
    "fields": {
      "attrs": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "bg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "fg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "text": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "underline": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "RenderUnderline"
        }
      },
      "width_hint": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      }
    },
    "kind": "object"
  },
  "RenderUnderline": {
    "kind": "enum",
    "values": [
      "single",
      "double",
      "curly",
      "dotted",
      "dashed"
    ]
  },
  "ReportAgentResult": {
    "additional_properties": false,
    "fields": {
      "session": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "source": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "AgentReportSource"
        }
      },
      "state": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "AgentState"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "ResizeSurfaceResult": {
    "additional_properties": false,
    "fields": {
      "accepted": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "reservation_id": {
        "nullable": true,
        "presence": "required",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "ResolveTerminalResult": {
    "additional_properties": false,
    "fields": {
      "exit": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalExit"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "launch_spec": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "JsonValue"
        }
      },
      "lifecycle": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalLifecycle"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspace_key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "ResourceSelectors": {
    "additional_properties": false,
    "fields": {
      "agent": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "browser": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "client": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "frontend_projection": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "machine": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "notification": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "pairing_request": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "pane": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "screen": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "session": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "sidebar_view": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "split": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "stream": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "tab": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "RunResult": {
    "additional_properties": false,
    "fields": {
      "already_exited": {
        "nullable": false,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "exit": {
        "nullable": true,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "ref",
          "name": "TerminalExit"
        }
      },
      "lifecycle": {
        "nullable": false,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "ref",
          "name": "TerminalLifecycle"
        }
      },
      "pane": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "screen": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "required",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspace": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "Screen": {
    "additional_properties": false,
    "fields": {
      "active": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "active_pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "layout": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Layout"
        }
      },
      "name": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "panes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Pane"
          },
          "kind": "array"
        }
      },
      "short_id": {
        "constraints": [
          {
            "pattern": "^[a-z0-9]{6}$"
          }
        ],
        "nullable": false,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "zoomed_pane": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "SetCellPixelsResult": {
    "additional_properties": false,
    "fields": {
      "failures": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "CellPixelFailure"
          },
          "kind": "array"
        }
      },
      "resizes": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "CellPixelResize"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "ShutdownDaemonResult": {
    "additional_properties": false,
    "fields": {
      "accepted": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "pid": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "SidebarPluginResult": {
    "additional_properties": false,
    "fields": {
      "error": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "retry_after_ms": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "Size": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "constraints": [
          {
            "maximum": 10000,
            "minimum": 1
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "rows": {
        "constraints": [
          {
            "maximum": 10000,
            "minimum": 1
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      }
    },
    "kind": "object"
  },
  "SplitDirection": {
    "kind": "enum",
    "values": [
      "right",
      "down"
    ]
  },
  "SurfaceResult": {
    "additional_properties": false,
    "fields": {
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": true,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "Tab": {
    "additional_properties": false,
    "fields": {
      "browser_error": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "browser_frames_stalled": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "browser_source": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "external",
            "launched"
          ]
        }
      },
      "browser_status": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "enum",
          "values": [
            "starting",
            "live",
            "failed"
          ]
        }
      },
      "dead": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "kind": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "pty",
            "browser"
          ]
        }
      },
      "name": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "notification": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "ref",
          "name": "NotificationMarker"
        }
      },
      "short_id": {
        "constraints": [
          {
            "pattern": "^[a-z0-9]{6}$"
          }
        ],
        "nullable": false,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "size": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Size"
        }
      },
      "supports_clear_history_key_fallback": {
        "capability": "clear-history-key-v1",
        "nullable": false,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": true,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_resource_id": {
        "constraints": [
          {
            "pattern": "^term_[0-9a-f]{32}$"
          }
        ],
        "nullable": true,
        "presence": "optional",
        "since": 10,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "title": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "TerminalColors": {
    "additional_properties": false,
    "fields": {
      "bg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "cursor": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "cursor_blink": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "cursor_style": {
        "nullable": true,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "ref",
          "name": "CursorStyle"
        }
      },
      "fg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "palette": {
        "constraints": [
          "Decimal string keys are palette indexes 0 through 255."
        ],
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "map",
          "values": {
            "kind": "ref",
            "name": "ColorHex"
          }
        }
      },
      "selection_bg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "selection_fg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      }
    },
    "kind": "object"
  },
  "TerminalEventsResult": {
    "additional_properties": false,
    "fields": {
      "events": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "TerminalRegistryEvent"
          },
          "kind": "array"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "TerminalExit": {
    "additional_properties": false,
    "fields": {
      "exited_at_ms": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "outcome": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalExitOutcome"
        }
      }
    },
    "kind": "object"
  },
  "TerminalExitOutcome": {
    "kind": "tagged_union",
    "tag": "kind",
    "variants": {
      "exit": {
        "additional_properties": false,
        "fields": {
          "code": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "int32"
            }
          },
          "kind": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "exit"
            }
          }
        },
        "kind": "object"
      },
      "signal": {
        "additional_properties": false,
        "fields": {
          "core_dumped": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "boolean"
            }
          },
          "kind": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "signal"
            }
          },
          "signal": {
            "constraints": [
              {
                "minimum": 1
              }
            ],
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "int32"
            }
          }
        },
        "kind": "object"
      },
      "unknown": {
        "additional_properties": false,
        "fields": {
          "kind": {
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "literal",
              "value": "unknown"
            }
          },
          "reason": {
            "constraints": [
              {
                "min_length": 1
              }
            ],
            "nullable": false,
            "presence": "required",
            "type": {
              "kind": "scalar",
              "name": "string"
            }
          }
        },
        "kind": "object"
      }
    }
  },
  "TerminalKey": {
    "kind": "enum",
    "values": [
      "unidentified",
      "backquote",
      "backslash",
      "bracket-left",
      "bracket-right",
      "comma",
      "digit0",
      "digit1",
      "digit2",
      "digit3",
      "digit4",
      "digit5",
      "digit6",
      "digit7",
      "digit8",
      "digit9",
      "equal",
      "a",
      "b",
      "c",
      "d",
      "e",
      "f",
      "g",
      "h",
      "i",
      "j",
      "k",
      "l",
      "m",
      "n",
      "o",
      "p",
      "q",
      "r",
      "s",
      "t",
      "u",
      "v",
      "w",
      "x",
      "y",
      "z",
      "minus",
      "period",
      "quote",
      "semicolon",
      "slash",
      "backspace",
      "enter",
      "space",
      "tab",
      "delete",
      "end",
      "home",
      "insert",
      "page-down",
      "page-up",
      "arrow-down",
      "arrow-left",
      "arrow-right",
      "arrow-up",
      "numpad0",
      "numpad1",
      "numpad2",
      "numpad3",
      "numpad4",
      "numpad5",
      "numpad6",
      "numpad7",
      "numpad8",
      "numpad9",
      "numpad-add",
      "numpad-backspace",
      "numpad-comma",
      "numpad-decimal",
      "numpad-divide",
      "numpad-enter",
      "numpad-equal",
      "numpad-multiply",
      "numpad-subtract",
      "numpad-up",
      "numpad-down",
      "numpad-right",
      "numpad-left",
      "numpad-begin",
      "numpad-home",
      "numpad-end",
      "numpad-insert",
      "numpad-delete",
      "numpad-page-up",
      "numpad-page-down",
      "escape",
      "f1",
      "f2",
      "f3",
      "f4",
      "f5",
      "f6",
      "f7",
      "f8",
      "f9",
      "f10",
      "f11",
      "f12",
      "f13",
      "f14",
      "f15",
      "f16",
      "f17",
      "f18",
      "f19",
      "f20"
    ]
  },
  "TerminalKeyAction": {
    "kind": "enum",
    "values": [
      "press",
      "release",
      "repeat"
    ]
  },
  "TerminalKeyInput": {
    "additional_properties": false,
    "constraints": [
      "consumed_mods must be a subset of mods.",
      "unshifted_codepoint, shifted_codepoint, and base_layout_codepoint contain exactly one Unicode scalar when present.",
      "utf8 contains no control characters.",
      "macos_option_as_alt may be false only when Alt is active and consumed."
    ],
    "fields": {
      "action": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "TerminalKeyAction"
        }
      },
      "base_layout_codepoint": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "composing": {
        "default": false,
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "consumed_mods": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalModifiers"
        }
      },
      "key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalKey"
        }
      },
      "macos_option_as_alt": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "mods": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalModifiers"
        }
      },
      "shifted_codepoint": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "unshifted_codepoint": {
        "default": null,
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "utf8": {
        "constraints": [
          {
            "max_length": 4096
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "TerminalLifecycle": {
    "kind": "enum",
    "values": [
      "launching",
      "adopting",
      "running",
      "exited",
      "tombstoned"
    ]
  },
  "TerminalModifiers": {
    "additional_properties": false,
    "fields": {
      "alt": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "caps_lock": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "control": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "num_lock": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "shift": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "super": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      }
    },
    "kind": "object"
  },
  "TerminalPlacement": {
    "additional_properties": false,
    "fields": {
      "already_exited": {
        "nullable": false,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "exit": {
        "nullable": true,
        "presence": "required",
        "since": 11,
        "type": {
          "kind": "ref",
          "name": "TerminalExit"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "lifecycle": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalLifecycle"
        }
      },
      "pane": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "replayed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "screen": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspace": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "TerminalRecord": {
    "additional_properties": false,
    "fields": {
      "exit": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalExit"
        }
      },
      "launch_spec": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "JsonValue"
        }
      },
      "lifecycle": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "TerminalLifecycle"
        }
      },
      "terminal_id": {
        "constraints": [
          {
            "format": "UUIDv4 hex without dashes",
            "pattern": "^[0-9a-f]{32}$"
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_incarnation": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace_key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "TerminalRegistryEvent": {
    "additional_properties": false,
    "fields": {
      "kind": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "mutation_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "origin": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "result": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "JsonValue"
        }
      },
      "terminal_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspace_key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "Tree": {
    "additional_properties": false,
    "fields": {
      "generation": {
        "capability": "workspace-registry-v1",
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "pane_revision": {
        "nullable": false,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "registry_id": {
        "capability": "workspace-registry-v1",
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "optional",
        "since": 9,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspace_revision": {
        "capability": "workspace-registry-v1",
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "workspaces": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Workspace"
          },
          "kind": "array"
        }
      }
    },
    "kind": "object"
  },
  "ViewAttachmentOutcome": {
    "kind": "enum",
    "values": [
      "applied",
      "passive",
      "superseded"
    ]
  },
  "VtStateResult": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "data": {
        "constraints": [
          {
            "encoding": "standard base64"
          }
        ],
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "kitty_graphics_state": {
        "nullable": false,
        "presence": "optional",
        "since": 10,
        "type": {
          "kind": "ref",
          "name": "KittyGraphicsState"
        }
      },
      "kitty_image_aliases": {
        "nullable": false,
        "presence": "optional",
        "since": 9,
        "type": {
          "items": {
            "kind": "ref",
            "name": "KittyImageAlias"
          },
          "kind": "array"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      }
    },
    "kind": "object"
  },
  "WaitForResult": {
    "additional_properties": false,
    "fields": {
      "elapsed_ms": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "matched": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": true
        }
      },
      "text": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "Workspace": {
    "additional_properties": false,
    "fields": {
      "active": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "key": {
        "capability": "workspace-registry-v1",
        "constraints": [
          {
            "format": "lowercase canonical UUID"
          }
        ],
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "name": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "screens": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "Screen"
          },
          "kind": "array"
        }
      },
      "short_id": {
        "constraints": [
          {
            "pattern": "^[a-z0-9]{6}$"
          }
        ],
        "nullable": false,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "WorkspaceMutationResult": {
    "additional_properties": false,
    "fields": {
      "changed": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "replayed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "ZoomPaneResult": {
    "additional_properties": false,
    "fields": {
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "zoomed": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "zoomed_pane": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  }
};
export const COMMAND_SCHEMAS: Readonly<Record<string, CommandSchema>> = {
  "apply-layout": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "layout must contain at least one leaf or stack member.",
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "layout": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "DeclarativeLayout"
          }
        },
        "name": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ApplyLayoutResult"
    }
  },
  "attach-surface": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows must be supplied together.",
        "Browser surfaces reject mode:render."
      ],
      "fields": {
        "cols": {
          "capability": "attach-initial-size",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "mode": {
          "default": "bytes",
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "enum",
            "values": [
              "bytes",
              "render"
            ]
          }
        },
        "rows": {
          "capability": "attach-initial-size",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-activate": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-back": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-forward": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-frame-presented": {
    "request": {
      "additional_properties": false,
      "fields": {
        "frame_seq": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-insert-text": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "text": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-key": {
    "request": {
      "additional_properties": false,
      "fields": {
        "code": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "kind": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "enum",
            "values": [
              "down",
              "up"
            ]
          }
        },
        "modifiers": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "text": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "windows_virtual_key_code": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-key-press": {
    "request": {
      "additional_properties": false,
      "fields": {
        "code": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "modifiers": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "text": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "windows_virtual_key_code": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-mouse": {
    "request": {
      "additional_properties": false,
      "fields": {
        "button": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "click_count": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "frame_seq": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "kind": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "enum",
            "values": [
              "down",
              "up",
              "move"
            ]
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "x_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        },
        "y_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-mouse-guarded": {
    "request": {
      "additional_properties": false,
      "fields": {
        "button": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "click_count": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "frame_seq": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "kind": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "enum",
            "values": [
              "down",
              "up",
              "move"
            ]
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "x_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        },
        "y_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-navigate": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "url": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-reload": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-wheel": {
    "request": {
      "additional_properties": false,
      "fields": {
        "delta_y_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        },
        "frame_seq": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "x_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        },
        "y_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "browser-wheel-guarded": {
    "request": {
      "additional_properties": false,
      "fields": {
        "delta_y_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        },
        "frame_seq": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "x_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        },
        "y_px": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "clear-history": {
    "request": {
      "additional_properties": false,
      "fields": {
        "fallback_key": {
          "capability": "clear-history-key-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "ref",
            "name": "TerminalKeyInput"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "clear-window-title": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "client-focus": {
    "request": {
      "additional_properties": false,
      "fields": {
        "client_id": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "additional_properties": false,
      "fields": {
        "pane": {
          "nullable": true,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "tab": {
          "nullable": true,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    }
  },
  "close-pane": {
    "request": {
      "additional_properties": false,
      "fields": {
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "close-provider-managed-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "workspace and key must identify the same live provider-managed workspace."
      ],
      "fields": {
        "authority": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ProviderWorkspaceMutationResult"
    }
  },
  "close-screen": {
    "request": {
      "additional_properties": false,
      "fields": {
        "screen": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "close-surface": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "close-terminal": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "origin and mutation_id are either both present or both absent."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "terminal_id": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "terminal_incarnation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "CloseTerminalResult"
    }
  },
  "close-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "At least one of workspace and key must be supplied; both must identify the same workspace when supplied.",
        "origin and mutation_id are either both present or both absent."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "key": {
          "capability": "workspace-registry-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "WorkspaceMutationResult"
    }
  },
  "copy": {
    "request": {
      "additional_properties": false,
      "fields": {
        "mode": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "enum",
            "values": [
              "screen",
              "selection",
              "scrollback"
            ]
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "CopyResult"
    }
  },
  "create-surface-with-receipt": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "operation is one of new-tab, run-command, new-browser-tab, new-workspace, new-screen, new-pane, new-pane-right, split-right, or split-down.",
        "Each operation admits only its documented selector and option fields.",
        "idempotency_key names one execution attempt and defaults to receipt.",
        "cols and rows must be supplied together."
      ],
      "fields": {
        "argv": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "items": {
              "kind": "scalar",
              "name": "string"
            },
            "kind": "array"
          }
        },
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "cwd": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "idempotency_key": {
          "capability": "creation-attempt-keys-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "operation": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "receipt": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "selector_fallbacks": {
          "default": [],
          "nullable": false,
          "presence": "optional",
          "type": {
            "items": {
              "kind": "ref",
              "name": "ResourceSelectors"
            },
            "kind": "array",
            "max_items": 7
          }
        },
        "selectors": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "ResourceSelectors"
          }
        },
        "url": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "width": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "float32"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "JsonValue"
    }
  },
  "create-terminal": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "At least one of workspace and key must be supplied; when both are supplied they must identify the same workspace.",
        "argv and command are mutually exclusive and must be nonempty when supplied.",
        "cols and rows must be supplied together.",
        "origin and mutation_id are either both present or both absent.",
        "terminal_id may be supplied only when origin and mutation_id are both present."
      ],
      "fields": {
        "argv": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "items": {
              "kind": "scalar",
              "name": "string"
            },
            "kind": "array",
            "min_items": 1
          }
        },
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "command": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "cwd": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "key": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "name": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "terminal_id": {
          "constraints": [
            {
              "format": "32-character lowercase UUIDv4 hex without dashes",
              "pattern": "^[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}$"
            }
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "TerminalPlacement"
    }
  },
  "create-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "origin and mutation_id are either both present or both absent.",
        "At most 4096 live workspaces may exist; tombstoned keys cannot be reused."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "key": {
          "constraints": [
            {
              "format": "lowercase canonical UUID"
            }
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "name": {
          "constraints": [
            {
              "max_utf8_bytes": 1024
            }
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "WorkspaceMutationResult"
    }
  },
  "detach-attached-view": {
    "request": {
      "additional_properties": false,
      "fields": {
        "lease": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "AttachedViewOutcomeResult"
    }
  },
  "detach-client": {
    "request": {
      "additional_properties": false,
      "fields": {
        "client": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "export-layout": {
    "request": {
      "additional_properties": false,
      "fields": {
        "screen": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ExportLayoutResult"
    }
  },
  "focus-direction": {
    "request": {
      "additional_properties": false,
      "fields": {
        "dir": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "PaneDirection"
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "FocusDirectionResult"
    }
  },
  "focus-pane": {
    "request": {
      "additional_properties": false,
      "fields": {
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "get-browser-provider": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "BrowserProviderSnapshot"
    }
  },
  "get-cell-pixels": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "GetCellPixelsResult"
    }
  },
  "get-frontend-projection": {
    "request": {
      "additional_properties": false,
      "fields": {
        "frontend": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "scope": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "subject_key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "FrontendProjection"
    }
  },
  "identify": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "IdentifyResult"
    }
  },
  "ids": {
    "request": {
      "additional_properties": false,
      "fields": {
        "kind": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "enum",
            "values": [
              "workspace",
              "screen",
              "pane",
              "surface"
            ]
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "IdsResult"
    }
  },
  "journal-frontend-event": {
    "request": {
      "additional_properties": false,
      "fields": {
        "event": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "FrontendJournalEvent"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "additional_properties": false,
      "fields": {
        "committed": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "literal",
            "value": true
          }
        }
      },
      "kind": "object"
    }
  },
  "list-agents": {
    "request": {
      "additional_properties": false,
      "fields": {
        "state": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "AgentState"
          }
        },
        "surface": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ListAgentsResult"
    }
  },
  "list-clients": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "items": {
        "kind": "ref",
        "name": "ClientInfo"
      },
      "kind": "array"
    }
  },
  "list-terminals": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ListTerminalsResult"
    }
  },
  "list-workspaces": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "Tree"
    }
  },
  "machine-usage": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "MachineUsageResult"
    }
  },
  "mark-workspaces-provider-managed": {
    "request": {
      "additional_properties": false,
      "fields": {
        "authority": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "mint-terminal-renderer": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "ttl_ms": {
          "constraints": [
            {
              "maximum": 60000,
              "minimum": 1
            }
          ],
          "default": 30000,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "MintTerminalRendererResult"
    }
  },
  "mint-terminal-renderer-by-terminal": {
    "request": {
      "additional_properties": false,
      "fields": {
        "terminal": {
          "constraints": [
            {
              "pattern": "^term_[0-9a-f]{32}$"
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "ttl_ms": {
          "constraints": [
            {
              "maximum": 60000,
              "minimum": 1
            }
          ],
          "default": 30000,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "MintTerminalRendererResult"
    }
  },
  "move-tab": {
    "request": {
      "additional_properties": false,
      "fields": {
        "index": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "move-terminal": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "origin and mutation_id are either both present or both absent."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "terminal_id": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "terminal_incarnation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace_key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "MoveTerminalResult"
    }
  },
  "move-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "At least one of workspace and key must be supplied; both must identify the same workspace when supplied.",
        "origin and mutation_id are either both present or both absent."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "index": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "key": {
          "capability": "workspace-registry-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "WorkspaceMutationResult"
    }
  },
  "new-browser-tab": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "url": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "new-pane": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "new-pane-right": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "Omitted width defaults to two thirds.",
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "width": {
          "constraints": [
            {
              "maximum": 1.0,
              "minimum": 0.1
            }
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "float32"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "new-screen": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "new-tab": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "cwd": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "new-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "name": {
          "constraints": [
            {
              "max_utf8_bytes": 1024
            }
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "notify": {
    "request": {
      "additional_properties": false,
      "fields": {
        "body": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "level": {
          "default": "info",
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "NotificationLevel"
          }
        },
        "surface": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "title": {
          "constraints": [
            {
              "min_length": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "NotifyResult"
    }
  },
  "pairing-response": {
    "request": {
      "additional_properties": false,
      "fields": {
        "approve": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "request": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "pane-neighbor": {
    "request": {
      "additional_properties": false,
      "fields": {
        "dir": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "PaneDirection"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "PaneNeighborResult"
    }
  },
  "ping": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "PingResult"
    }
  },
  "process-info": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ProcessInfoResult"
    }
  },
  "put-frontend-projection": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "origin and mutation_id are either both present or both absent.",
        "Serialized projection must be at most 1048576 bytes."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "description": "Accepted by the current decoder but ignored for projection writes.",
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_projection_revision": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "description": "Accepted by the current decoder but ignored for projection writes.",
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "frontend": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "projection": {
          "nullable": true,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "JsonValue"
          }
        },
        "schema_version": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "scope": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "subject_key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "FrontendProjection"
    }
  },
  "read-screen": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ReadScreenResult"
    }
  },
  "read-scrollback": {
    "request": {
      "additional_properties": false,
      "fields": {
        "count": {
          "constraints": [
            {
              "maximum": 65535,
              "minimum": 0
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "start": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ReadScrollbackResult"
    }
  },
  "register-browser-provider": {
    "request": {
      "additional_properties": false,
      "fields": {
        "authentication": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "BrowserProviderAuthentication"
          }
        },
        "bearer_token": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "endpoint": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "provider_id": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "targets": {
          "nullable": false,
          "presence": "required",
          "type": {
            "items": {
              "kind": "ref",
              "name": "BrowserProviderTarget"
            },
            "kind": "array"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "BrowserProviderSnapshot"
    }
  },
  "release-attached-view-size": {
    "request": {
      "additional_properties": false,
      "fields": {
        "lease": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "AttachedViewOutcomeResult"
    }
  },
  "release-surface-size": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "reload-config": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "additional_properties": false,
      "fields": {
        "path": {
          "nullable": true,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "reloaded": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "literal",
            "value": true
          }
        }
      },
      "kind": "object"
    }
  },
  "rename-pane": {
    "request": {
      "additional_properties": false,
      "fields": {
        "name": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "rename-provider-managed-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "workspace and key must identify the same live provider-managed workspace."
      ],
      "fields": {
        "authority": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "key": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "name": {
          "constraints": [
            {
              "max_utf8_bytes": 1024
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ProviderWorkspaceMutationResult"
    }
  },
  "rename-screen": {
    "request": {
      "additional_properties": false,
      "fields": {
        "name": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "screen": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "rename-surface": {
    "request": {
      "additional_properties": false,
      "fields": {
        "name": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "rename-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "At least one of workspace and key must be supplied; both must identify the same workspace when supplied.",
        "origin and mutation_id are either both present or both absent."
      ],
      "fields": {
        "expected_generation": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "expected_revision": {
          "aliases": [
            "expected_terminal_revision"
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "key": {
          "capability": "workspace-registry-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "mutation_id": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "name": {
          "constraints": [
            {
              "max_utf8_bytes": 1024
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "origin": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "workspace": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "WorkspaceMutationResult"
    }
  },
  "report-agent": {
    "request": {
      "additional_properties": false,
      "fields": {
        "session": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "source": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "AgentReportSource"
          }
        },
        "state": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "AgentState"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ReportAgentResult"
    }
  },
  "report-focus": {
    "request": {
      "additional_properties": false,
      "fields": {
        "client_id": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "tab": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "resize-attached-view": {
    "request": {
      "additional_properties": false,
      "fields": {
        "cols": {
          "constraints": [
            {
              "clamped_maximum": 10000,
              "clamped_minimum": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "lease": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "rows": {
          "constraints": [
            {
              "clamped_maximum": 10000,
              "clamped_minimum": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "AttachedViewResizeResult"
    }
  },
  "resize-surface": {
    "request": {
      "additional_properties": false,
      "fields": {
        "cols": {
          "constraints": [
            {
              "clamped_maximum": 10000,
              "clamped_minimum": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "rows": {
          "constraints": [
            {
              "clamped_maximum": 10000,
              "clamped_minimum": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ResizeSurfaceResult"
    }
  },
  "resolve-terminal": {
    "request": {
      "additional_properties": false,
      "fields": {
        "terminal_id": {
          "constraints": [
            {
              "format": "UUIDv4 hex without dashes",
              "pattern": "^[0-9a-f]{32}$"
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ResolveTerminalResult"
    }
  },
  "run": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "Exactly one of argv and command must be supplied.",
        "pane and new_workspace:true are mutually exclusive.",
        "key is valid only with new_workspace:true.",
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "argv": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "items": {
              "kind": "scalar",
              "name": "string"
            },
            "kind": "array",
            "min_items": 1
          }
        },
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "command": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "cwd": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "key": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "name": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "new_workspace": {
          "default": false,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "RunResult"
    }
  },
  "scroll-surface": {
    "request": {
      "additional_properties": false,
      "fields": {
        "delta": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "int64"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "select-screen": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "When both index and delta are supplied, index wins."
      ],
      "fields": {
        "delta": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "int64"
          }
        },
        "index": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "select-tab": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "When both index and delta are supplied, index wins."
      ],
      "fields": {
        "delta": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "int64"
          }
        },
        "index": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "select-workspace": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "When both index and delta are supplied, index wins."
      ],
      "fields": {
        "delta": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "int64"
          }
        },
        "index": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "send": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "When both are present, UTF-8 text bytes precede decoded bytes."
      ],
      "fields": {
        "bytes": {
          "constraints": [
            {
              "encoding": "standard base64"
            }
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Base64"
          }
        },
        "paste": {
          "default": false,
          "nullable": false,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "text": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "send-key": {
    "request": {
      "additional_properties": false,
      "fields": {
        "keys": {
          "constraints": [
            {
              "syntax": "lowercase modifier+key chords"
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "items": {
              "kind": "scalar",
              "name": "string"
            },
            "kind": "array",
            "min_items": 1
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-cell-pixels": {
    "request": {
      "additional_properties": false,
      "fields": {
        "height_px": {
          "constraints": [
            {
              "clamped_minimum": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "width_px": {
          "constraints": [
            {
              "clamped_minimum": 1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SetCellPixelsResult"
    }
  },
  "set-client-info": {
    "request": {
      "additional_properties": false,
      "fields": {
        "capabilities": {
          "constraints": [
            "Advertises additive client capabilities for this connection."
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "items": {
              "kind": "scalar",
              "name": "string"
            },
            "kind": "array"
          }
        },
        "kind": {
          "constraints": [
            "Control characters become spaces; at most 64 Unicode characters are retained."
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "name": {
          "constraints": [
            "Control characters become spaces; at most 64 Unicode characters are retained."
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-client-sizing": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "exclusive:true requires client and enabled:true.",
        "Omitting client is valid only with enabled:true and restores all clients for the surface."
      ],
      "fields": {
        "client": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "enabled": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "exclusive": {
          "default": false,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-default-colors": {
    "request": {
      "additional_properties": false,
      "fields": {
        "bg": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "ColorHex"
          }
        },
        "complete": {
          "default": false,
          "nullable": false,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "cursor": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "ref",
            "name": "ColorHex"
          }
        },
        "cursor_blink": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "cursor_style": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "ref",
            "name": "CursorStyle"
          }
        },
        "fg": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "ColorHex"
          }
        },
        "palette": {
          "constraints": [
            "Decimal string keys are palette indexes 0 through 255."
          ],
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "map",
            "values": {
              "kind": "ref",
              "name": "ColorHex"
            }
          }
        },
        "selection_bg": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "ref",
            "name": "ColorHex"
          }
        },
        "selection_fg": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "ref",
            "name": "ColorHex"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-ratio": {
    "request": {
      "additional_properties": false,
      "fields": {
        "dir": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "SplitDirection"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "ratio": {
          "constraints": [
            {
              "clamped_maximum": 0.95,
              "clamped_minimum": 0.05
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float32"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-split-ratio": {
    "request": {
      "additional_properties": false,
      "fields": {
        "ratio": {
          "constraints": [
            {
              "clamped_maximum": 0.95,
              "clamped_minimum": 0.05
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float32"
          }
        },
        "split": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "transaction": {
          "capability": "layout-undo-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-viewport-pane-width": {
    "request": {
      "additional_properties": false,
      "fields": {
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "transaction": {
          "capability": "layout-undo-v1",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        },
        "width": {
          "constraints": [
            {
              "maximum": 1.0,
              "minimum": 0.1
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "float32"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "set-window-title": {
    "request": {
      "additional_properties": false,
      "fields": {
        "title": {
          "constraints": [
            "C0 controls are sanitized before OSC output."
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "shutdown-daemon": {
    "request": {
      "additional_properties": false,
      "fields": {
        "force": {
          "capability": "daemon-handoff-force-v1",
          "default": false,
          "nullable": false,
          "presence": "optional",
          "since": 10,
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "generation": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "pid": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint32"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ShutdownDaemonResult"
    }
  },
  "sidebar-plugin": {
    "request": {
      "additional_properties": false,
      "fields": {
        "cols": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "relaunch": {
          "default": false,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "rows": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SidebarPluginResult"
    }
  },
  "split": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "cols and rows affect sizing only when both are present."
      ],
      "fields": {
        "cols": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        },
        "dir": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "SplitDirection"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "rows": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint16"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "SurfaceResult"
    }
  },
  "subscribe": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "capability": "surface-subscribe-filter",
          "default": null,
          "nullable": true,
          "presence": "optional",
          "since": 9,
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "tree_events": {
          "default": "coarse",
          "nullable": true,
          "presence": "optional",
          "since": 7,
          "type": {
            "kind": "enum",
            "values": [
              "coarse",
              "deltas"
            ]
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "swap-pane": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "Exactly one of dir and target must be supplied."
      ],
      "fields": {
        "dir": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "PaneDirection"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "target": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "EmptyResult"
    }
  },
  "terminal-events": {
    "request": {
      "additional_properties": false,
      "fields": {
        "after_revision": {
          "default": 0,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "TerminalEventsResult"
    }
  },
  "undo-layout": {
    "request": {
      "additional_properties": false,
      "constraints": [
        "confirm_close requires the exact preview revision."
      ],
      "fields": {
        "confirm_close": {
          "default": false,
          "nullable": false,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "boolean"
          }
        },
        "pane": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "revision": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "LayoutUndoResult"
    }
  },
  "unregister-browser-provider": {
    "request": {
      "additional_properties": false,
      "fields": {},
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "BrowserProviderUnregisterResult"
    }
  },
  "vt-state": {
    "request": {
      "additional_properties": false,
      "fields": {
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "VtStateResult"
    }
  },
  "wait-for": {
    "request": {
      "additional_properties": false,
      "fields": {
        "pattern": {
          "constraints": [
            {
              "syntax": "Rust regex"
            }
          ],
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "string"
          }
        },
        "surface": {
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        },
        "timeout_ms": {
          "description": "Zero performs one immediate check.",
          "nullable": false,
          "presence": "required",
          "type": {
            "kind": "scalar",
            "name": "uint64"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "WaitForResult"
    }
  },
  "zoom-pane": {
    "request": {
      "additional_properties": false,
      "fields": {
        "mode": {
          "default": "toggle",
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "enum",
            "values": [
              "toggle",
              "on",
              "off"
            ]
          }
        },
        "pane": {
          "default": null,
          "nullable": true,
          "presence": "optional",
          "type": {
            "kind": "ref",
            "name": "Id"
          }
        }
      },
      "kind": "object"
    },
    "result": {
      "kind": "ref",
      "name": "ZoomPaneResult"
    }
  }
};
export const EVENT_SCHEMAS: Readonly<Record<string, TypeSchema>> = {
  "agent-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "agent-changed"
        }
      },
      "session": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "source": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "AgentSource"
        }
      },
      "state": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "AgentState"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "updated_at_ms": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "bell": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "bell"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "browser-state": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "error": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "browser-state"
        }
      },
      "frame": {
        "description": "The initial browser-state includes the latest frame when one exists; later state updates omit it.",
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "BrowserFrame"
        }
      },
      "frames_stalled": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "status": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "starting",
            "live",
            "failed"
          ]
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "title": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "url": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "client-attached": {
    "additional_properties": false,
    "fields": {
      "client": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "client-attached"
        }
      },
      "kind": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "name": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "transport": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "unix",
            "ws"
          ]
        }
      }
    },
    "kind": "object"
  },
  "client-changed": {
    "additional_properties": false,
    "fields": {
      "client": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "client-changed"
        }
      },
      "kind": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "name": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "client-detached": {
    "additional_properties": false,
    "fields": {
      "client": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "client-detached"
        }
      }
    },
    "kind": "object"
  },
  "client-list-invalidated": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "client-list-invalidated"
        }
      }
    },
    "kind": "object"
  },
  "colors-changed": {
    "additional_properties": false,
    "fields": {
      "bg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "cursor": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "cursor_blink": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "cursor_style": {
        "nullable": true,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "CursorStyle"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "colors-changed"
        }
      },
      "fg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "palette": {
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "map",
          "values": {
            "kind": "ref",
            "name": "ColorHex"
          }
        }
      },
      "selection_bg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "selection_fg": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "config-reload-requested": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "config-reload-requested"
        }
      }
    },
    "kind": "object"
  },
  "detached": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "detached"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "empty": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "empty"
        }
      }
    },
    "kind": "object"
  },
  "frame": {
    "additional_properties": false,
    "fields": {
      "data": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "frame"
        }
      },
      "height": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "seq": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "width": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      }
    },
    "kind": "object"
  },
  "frontend-projection-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "frontend-projection-changed"
        }
      },
      "frontend": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "mutation_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "origin": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "projection_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "scope": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "subject_key": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "graphics-status": {
    "additional_properties": false,
    "constraints": [
      "kitty-image-budget-worker-start-failed carries error.",
      "kitty-image-budget-update-failed carries retry_exhausted and summary.",
      "cell-pixel-update-retries-exhausted carries attempts, remaining, cell_width, and cell_height."
    ],
    "fields": {
      "attempts": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "cell_height": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "cell_width": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "error": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "graphics-status"
        }
      },
      "kind": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "enum",
          "values": [
            "kitty-image-budget-worker-start-failed",
            "kitty-image-budget-update-failed",
            "cell-pixel-update-retries-exhausted"
          ]
        }
      },
      "remaining": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "retry_exhausted": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "summary": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "layout-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "layout-changed"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "machine-usage-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "machine-usage-changed"
        }
      },
      "usage": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "MachineUsage"
        }
      }
    },
    "kind": "object"
  },
  "notification": {
    "additional_properties": false,
    "fields": {
      "body": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "notification"
        }
      },
      "level": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "NotificationLevel"
        }
      },
      "notification": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "title": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "output": {
    "additional_properties": false,
    "fields": {
      "colors": {
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "ref",
          "name": "TerminalColors"
        }
      },
      "data": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "output"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "overflow": {
    "additional_properties": false,
    "constraints": [
      "scope and surface are either both present for attach overflow or both absent for subscribe overflow."
    ],
    "fields": {
      "error": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "overflow"
        }
      },
      "scope": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "literal",
          "value": "surface"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "pairing-requested": {
    "additional_properties": false,
    "fields": {
      "code": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "pairing-requested"
        }
      },
      "expires_in": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "peer": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "request": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "pairing-resolved": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "pairing-resolved"
        }
      },
      "request": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "pane-added": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Pane"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "pane-added"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "pane-closed": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Pane"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "pane-closed"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "render-delta": {
    "additional_properties": false,
    "constraints": [
      "size is present if and only if the surface resized; every resize has full:true."
    ],
    "fields": {
      "cursor": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "RenderCursor"
        }
      },
      "default_bg": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "default_fg": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "render-delta"
        }
      },
      "full": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "graphics": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "RenderGraphicsDelta"
        }
      },
      "history_epoch": {
        "nullable": false,
        "presence": "optional",
        "since": 10,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderRow"
          },
          "kind": "array"
        }
      },
      "scrollback_rows": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "size": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "Size"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "render-state": {
    "additional_properties": false,
    "fields": {
      "cursor": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "RenderCursor"
        }
      },
      "default_bg": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "default_fg": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "ColorHex"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "render-state"
        }
      },
      "graphics": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "RenderGraphics"
        }
      },
      "history_epoch": {
        "nullable": false,
        "presence": "required",
        "since": 10,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "items": {
            "kind": "ref",
            "name": "RenderRow"
          },
          "kind": "array"
        }
      },
      "scrollback_rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint32"
        }
      },
      "size": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Size"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "resized": {
    "additional_properties": false,
    "constraints": [
      "At least one of replay and data is present; replay is canonical from protocol 7."
    ],
    "fields": {
      "colors": {
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "ref",
          "name": "TerminalColors"
        }
      },
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "data": {
        "description": "Protocol 6 compatibility field.",
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "resized"
        }
      },
      "kitty_graphics_state": {
        "nullable": false,
        "presence": "optional",
        "since": 10,
        "type": {
          "kind": "ref",
          "name": "KittyGraphicsState"
        }
      },
      "kitty_image_aliases": {
        "nullable": false,
        "presence": "optional",
        "since": 9,
        "type": {
          "items": {
            "kind": "ref",
            "name": "KittyImageAlias"
          },
          "kind": "array"
        }
      },
      "replay": {
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "screen-added": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Screen"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "screen-added"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "screen-closed": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Screen"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "screen-closed"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "screen-renamed": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Screen"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "screen-renamed"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "scroll-changed": {
    "additional_properties": false,
    "fields": {
      "at_bottom": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "boolean"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "scroll-changed"
        }
      },
      "offset": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "status": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "status"
        }
      },
      "message": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "surface-exited": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "surface-exited"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "surface-output": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "surface-output"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "surface-resize-failed": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "error": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "surface-resize-failed"
        }
      },
      "reservation_id": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "retry_after_ms": {
        "nullable": true,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "surface-resized": {
    "additional_properties": false,
    "fields": {
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "surface-resized"
        }
      },
      "reservation_id": {
        "nullable": true,
        "presence": "required",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "tab-added": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Tab"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "tab-added"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "tab-closed": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Tab"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "tab-closed"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "tab-renamed": {
    "additional_properties": false,
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Tab"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "tab-renamed"
        }
      },
      "pane": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "screen": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "terminal-registry-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "terminal-registry-changed"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "refetch": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "terminal-events-or-list-terminals"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "terminal_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "title-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "title-changed"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "title": {
        "nullable": false,
        "presence": "optional",
        "since": 7,
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "tree-changed": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "tree-changed"
        }
      }
    },
    "kind": "object"
  },
  "vt-state": {
    "additional_properties": false,
    "fields": {
      "colors": {
        "nullable": false,
        "presence": "optional",
        "since": 6,
        "type": {
          "kind": "ref",
          "name": "TerminalColors"
        }
      },
      "cols": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "data": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Base64"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "vt-state"
        }
      },
      "kitty_graphics_state": {
        "nullable": false,
        "presence": "optional",
        "since": 10,
        "type": {
          "kind": "ref",
          "name": "KittyGraphicsState"
        }
      },
      "kitty_image_aliases": {
        "nullable": false,
        "presence": "optional",
        "since": 9,
        "type": {
          "items": {
            "kind": "ref",
            "name": "KittyImageAlias"
          },
          "kind": "array"
        }
      },
      "rows": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint16"
        }
      },
      "surface": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      }
    },
    "kind": "object"
  },
  "window-title-requested": {
    "additional_properties": false,
    "fields": {
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "window-title-requested"
        }
      },
      "title": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      }
    },
    "kind": "object"
  },
  "workspace-added": {
    "additional_properties": false,
    "constraints": [
      "origin and mutation_id are either both present or both absent."
    ],
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Workspace"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "workspace-added"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "mutation_id": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "origin": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "workspace-closed": {
    "additional_properties": false,
    "constraints": [
      "origin and mutation_id are either both present or both absent."
    ],
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Workspace"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "workspace-closed"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "mutation_id": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "origin": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "workspace-moved": {
    "additional_properties": false,
    "constraints": [
      "origin and mutation_id are either both present or both absent."
    ],
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Workspace"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "workspace-moved"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "index": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      },
      "mutation_id": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "origin": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  },
  "workspace-renamed": {
    "additional_properties": false,
    "constraints": [
      "origin and mutation_id are either both present or both absent."
    ],
    "fields": {
      "entity": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Workspace"
        }
      },
      "event": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "literal",
          "value": "workspace-renamed"
        }
      },
      "generation": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "mutation_id": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "origin": {
        "nullable": false,
        "presence": "optional",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "registry_id": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "string"
        }
      },
      "workspace": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "ref",
          "name": "Id"
        }
      },
      "workspace_revision": {
        "nullable": false,
        "presence": "required",
        "type": {
          "kind": "scalar",
          "name": "uint64"
        }
      }
    },
    "kind": "object"
  }
};

export type CmuxAuthority = typeof COMMAND_METADATA[keyof typeof COMMAND_METADATA]["authority"];
export type CmuxProfile = keyof typeof PROFILES;
export type EmittedEventName = {
  [E in keyof typeof EVENT_METADATA]:
    typeof EVENT_METADATA[E]["emission"] extends "emitted" ? E : never;
}[keyof typeof EVENT_METADATA];
