# Peer link liveness: every timer and the worst case

When does acpmux decide a peer link is dead, and how soon does the redial start? The answer comes from four
places: the link's ping (`peer_link.rs`), ssh's own keepalive and ConnectTimeout (`peer.rs`), the redial
backoff, and the sleep detector. This page puts them in one table, with each worst case written as a sum of
named timers, so a slow reconnect can be checked against one sum.

The tables below are generated from the constants by `peer::liveness::markdown()`. The test
`peer::liveness::tests::the_doc_table_matches_the_constants` fails when a constant changes and this page does
not. To regenerate:

```sh
ACPMUX_WRITE_LIVENESS_TABLE=1 cargo test -p acpmux the_doc_table_matches_the_constants
```

Run it on cmux-ci (`cmux-ci test -- ...`), never on a person's Mac. Values are the defaults, with no
`ACPMUX_PEER_*` variable set.

<!-- liveness-table:begin (generated: peer::liveness::markdown) -->
| Timer | Value | Source | Decides |
|---|---|---|---|
| ping interval | 2 s | `peer_link::LinkTimings::ping_every` | a ping goes out this often; any byte from the peer answers it |
| silence budget (start) | 6 s | `LinkTimings::ping_every x ping_misses` | the link is dropped after this long with no byte from the peer |
| silence budget (cap) | 80 s | `peer_link::SilenceBudget::CAP` | the most the budget grows to for a peer that answers late |
| ssh keepalive | 45 s | `peer::SSH_ALIVE_INTERVAL_SECS x SSH_ALIVE_COUNT_MAX` | ssh ends the tunnel itself; a backstop under the ping |
| ssh connect | 3 s | `peer::SSH_CONNECT_SECS` | one ssh attempt gives up (ConnectTimeout) |
| ssh connect (slow) | 20 s | `peer::SSH_CONNECT_SLOW_SECS` | the same while waking a machine or after a banner timeout |
| first redial wait | 0.5 s | `peer_link::Backoff::BASE` | the first backoff step (drawn from its upper half) |
| redial wait cap (wanted) | 1 s | `peer_link::Backoff::WANTED_CAP` | the longest step while a client waits on the peer |
| redial wait cap | 60 s | `peer_link::Backoff::CAP` | the longest step when nobody waits |
| sleep check | 5 s | `peer_link::SleepWatch::EVERY` | how often the clocks are compared to notice a sleep |
| wake probe | 30 s | `peer_link::WAKE_PROBE` | after a wake, an open link must answer within this |
| link connect | 30 s | `LinkTimings::connect` | ssh, the tunnel and the WebSocket upgrade together |
| handshake | 90 s | `LinkTimings::handshake` | initialize and watch once the WebSocket is open |

| Worst case | Bound | Sum |
|---|---|---|
| dead link noticed | 8 s | silence budget 6 s + one ping interval 2 s |
| dead link noticed, budget grown | 82 s | silence cap 80 s + one ping interval 2 s |
| first redial attempt gives up | 11.5 s | noticed 8 s + first wait 0.5 s + ssh connect 3 s |
| first redial gives up, slow banner | 28.5 s | noticed 8 s + first wait 0.5 s + slow ssh connect 20 s |
| second redial begins, client waiting | 12.5 s | first attempt gave up 11.5 s + wanted cap 1 s |
| dead after a sleep noticed | 35 s | sleep check 5 s + wake probe 30 s |
<!-- liveness-table:end -->

## Reading a slow reconnect against it

- Under 12.5 s: one dead-link notice and at most one failed ssh attempt. Normal.
- 18 to 30 s: the sums above reach this only through the slow ssh connect (a banner timeout or a waking
  machine sets it, `Peer::ssh_connect_secs`) or a silence budget that grew for a peer that answered late
  (`SilenceBudget`). Check the run's log for `banner` and for the budget before blaming the network.
- Past 35 s: no default sum reaches it except a grown budget (up to 82 s) or a refused login
  (`Backoff::login_refused`, minutes). Either is visible in `host ls`.

The ssh keepalive (45 s) is a backstop: the link's own ping always notices first. A test
(`the_ssh_keepalive_stays_a_backstop_behind_the_ping`) keeps it that way.
