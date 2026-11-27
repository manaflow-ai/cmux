package pane

import (
	"encoding/json"
	"fmt"
)

// Session-level error codes. They live under cmux.protocol.* (TS lane wire
// decision 6) and every op may return them in addition to the codes its IR
// entry declares. The set matches the TS session plus decisions 13 and the
// Rust lane's R6 list.
const (
	CodeClosed         = "cmux.protocol.closed"          // transport closed before the result (retryable)
	CodeCancelled      = "cmux.protocol.cancelled"       // the caller sent cancel
	CodeUnknownOp      = "cmux.protocol.unknown_op"      // op (or stream op) not served here
	CodeUnknownStream  = "cmux.protocol.unknown_stream"  // event stream not served here
	CodeInvalidParams  = "cmux.protocol.invalid_params"  // params failed IR validation
	CodeInvalidResult  = "cmux.protocol.invalid_result"  // a result failed IR validation
	CodeInvalidEvent   = "cmux.protocol.invalid_event"   // event data failed IR validation
	CodeInternal       = "cmux.protocol.internal"        // handler failed; details are logged, not sent
	CodeCreditExceeded = "cmux.protocol.credit_exceeded" // byte stream sent past its credit
	CodeStreamAborted  = "cmux.protocol.stream_aborted"  // byte stream aborted
	CodeAuthRefused    = "cmux.protocol.auth_refused"    // missing, invalid or expired capability token
	CodeForbidden      = "cmux.protocol.forbidden"       // token does not grant the op's namespace or scope
	CodeBusy           = "cmux.protocol.busy"            // too many calls in flight (retryable)
	CodeBadMessage     = "cmux.protocol.bad_message"     // malformed envelope, id out of range, duplicate call id
	CodeTokenExpired   = "cmux.protocol.token_expired"   // token expired mid-session (retryable; send a fresh auth)
	CodeNotRouted      = "cmux.protocol.not_routed"      // the router was asked to carry a data-plane op
	CodeTooLarge       = "cmux.protocol.too_large"       // message above 16 MiB
)

var runtimeCodes = map[string]bool{
	CodeClosed: true, CodeCancelled: true, CodeUnknownOp: true, CodeUnknownStream: true,
	CodeInvalidParams: true, CodeInvalidResult: true, CodeInvalidEvent: true, CodeInternal: true,
	CodeCreditExceeded: true, CodeStreamAborted: true, CodeAuthRefused: true, CodeForbidden: true,
	CodeBusy: true, CodeBadMessage: true, CodeTokenExpired: true, CodeNotRouted: true, CodeTooLarge: true,
}

// IsRuntimeCode reports whether code is one of the session-level codes above.
func IsRuntimeCode(code string) bool { return runtimeCodes[code] }

// Error is a protocol error: the err envelope's payload.
type Error struct {
	Code      string
	Message   string
	Retryable bool
	Details   json.RawMessage
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Message) }

// Errorf builds a non-retryable *Error.
func Errorf(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}
