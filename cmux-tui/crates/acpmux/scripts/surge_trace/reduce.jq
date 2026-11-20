# Reduce one session's raw acpmux events (jq -s over `acpmux session tail --json` lines) into the
# ACPMUX_SURGE_TRACE shape that cmux #48220's coordinator_surge_flood_admission reads.
# Bodies are cut to kind / PR numbers / runner label / urgency; nothing else of the text is kept.
# Args: --argjson from MS --argjson to MS (arrival window, unix ms), --arg host NAME.

def text_of: (.msg.text // .msg.prompt // "") | tostring;
def prs: [scan("#([0-9]{4,6})") | .[0]] | unique;
def runner: (capture("(?i)runner[ _-]?label[: ]+`?(?<l>[A-Za-z0-9_.:-]+)") | .l)
  // (capture("(?i)runs-on[: ]+`?(?<l>[A-Za-z0-9_.:-]+)") | .l) // null;
def urgency: if test("(?i)\\bFIRE\\b") then "fire" elif test("(?i)\\bblock(ed|er)?\\b") then "block"
  elif test("\\?\\s*$|\\?\\s*\\n") then "question" else null end;
def prov: (.msg._meta.provenance // .msg.provenance // null);
def class_of: (.msg.class // .msg._meta.acpmux.class // .msg._meta.acpmux.sender.class
  // (prov | .class? ) // null)
  | if . == "blocker" then "block" elif . == "action" then "result"
    elif . == null then "result" else . end;
def person: (.msg._meta.origin.actor == "person" and .msg._meta.origin.verified == true);
def reduce_prov: if . == null then null else
  {kind, from, fromName, fromHarness, transport, verified,
   notice: (if .notice == null then null else
     {severity: .notice.severity, sender: .notice.sender,
      title: ((.notice.title // "") | tostring | ([prs[] | "#" + .] | join(" ")))} end)}
  | with_entries(select(.value != null)) end;
def keep_timeline: {turnId: .msg.turnId, turnSeq: .msg.turnSeq, status: .msg.status,
  stopReason: .msg.stopReason, promptId: .msg.promptId, toolCallId: .msg.toolCallId}
  | with_entries(select(.value != null));

. as $all
| ($all | map(select(.dir == "mux"))) as $mux
| ($mux | map(select((.kind == "user_message" or .kind == "queued" or .kind == "inbox")
     and (.msg.promptId != null) and .at >= $from and .at < $to))
   | group_by(.msg.promptId)
   | map(sort_by(.at) as $recs
     | ($recs | map(text_of) | map(select(length > 0)) | first // "") as $t
     | ($recs | map(prov) | map(select(. != null)) | first) as $p
     | ($recs[0]) as $r0
     | {
         at: $r0.at,
         promptId: $r0.msg.promptId,
         senderId: (($p.fromName // $p.from // $r0.msg.from) // (if ($recs | any(person)) then "person" else "unknown" end)),
         class: ($recs | map(class_of) | map(select(. != "result")) | first // "result"),
         person: ($recs | any(person)),
         provenance: ($p | reduce_prov),
         blocks: [{type: "text", text: ([($p.kind // "message")] + [($t | prs[]) | "#" + .]
            + [($t | runner) | select(. != null) | "runner " + .]
            + [($t | urgency) | select(. != null)] | join(" "))}],
         thread: ($recs | map(.msg.threadId) | map(select(. != null)) | first),
         textHint: ($t | urgency)
       })
   | sort_by(.at)) as $arrivals
| {
    host: $host,
    window: {from: $from, to: $to},
    replyTimeline: ($mux
      | map(select(.kind | test("^(user_message|turn_started|turn_result|turn_end|turn_error|status|permission_[a-z]+)$")))
      | map(select(.at < $to))
      | map({seq, at, dir, kind, msg: keep_timeline})),
    arrivals: ($arrivals | map(del(.textHint))),
    textHints: ($arrivals | map(select(.textHint != null)) | map({promptId, u: .textHint})),
    protectedIds: ($arrivals | map(select(
        .person or .class == "question" or .class == "block"
        or (.provenance.notice.severity // "") == "fire")) | map(.promptId))
  }
