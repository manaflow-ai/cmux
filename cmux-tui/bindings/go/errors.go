package cmux

import (
	"encoding/json"
	"errors"
	"fmt"
)

var (
	ErrInvalidID       = errors.New("cmux: invalid resource id")
	ErrInvalidSelector = errors.New("cmux: invalid selector")
	ErrInvalidArgument = errors.New("cmux: invalid argument")
	ErrTransport       = errors.New("cmux: transport failure")
	ErrProtocol        = errors.New("cmux: protocol violation")
	ErrClosed          = errors.New("cmux: closed")
)

// ResourceError preserves every structured protocol error field.
type ResourceError struct {
	Code      string
	Message   string
	Details   json.RawMessage
	Retryable bool
}

// DecodeDetails strictly decodes structured catalog details into a typed model.
func (e *ResourceError) DecodeDetails(target any) error {
	if e == nil {
		return fmt.Errorf("%w: cannot decode details from a nil resource error", ErrInvalidArgument)
	}
	if err := strictDecode(e.Details, target); err != nil {
		return &ProtocolError{Message: "cannot decode " + e.Code + " details: " + err.Error()}
	}
	return nil
}

type ConfirmationRequiredDetails struct {
	ConfirmationToken string   `json:"confirmation_token"`
	Revision          Decimal  `json:"revision"`
	ClosesPanes       []PaneID `json:"closes_panes"`
}

func (d *ConfirmationRequiredDetails) UnmarshalJSON(data []byte) error {
	type wireDetails ConfirmationRequiredDetails
	var decoded wireDetails
	if err := strictDecode(data, &decoded); err != nil {
		return err
	}
	if len(decoded.ConfirmationToken) < 1 || len(decoded.ConfirmationToken) > 128 {
		return fmt.Errorf("confirmation_token must contain 1 to 128 characters")
	}
	if len(decoded.ClosesPanes) == 0 {
		return fmt.Errorf("closes_panes must contain at least one pane ID")
	}
	*d = ConfirmationRequiredDetails(decoded)
	return nil
}

func (e *ResourceError) Error() string {
	if e == nil {
		return "<nil>"
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// IsCode allows callers to branch on stable protocol codes without parsing
// human messages.
func (e *ResourceError) IsCode(code string) bool {
	return e != nil && e.Code == code
}

type TransportError struct {
	Operation string
	Err       error
}

func (e *TransportError) Error() string {
	return fmt.Sprintf("cmux %s: %v", e.Operation, e.Err)
}
func (e *TransportError) Unwrap() error { return e.Err }
func (e *TransportError) Is(target error) bool {
	return target == ErrTransport
}

// MutationTransportUncertainError means a mutation request may have reached
// the server, but no structured response was observed. The SDK never retries
// automatically. Inspect state before retrying with a new idempotency key.
type MutationTransportUncertainError struct {
	Operation      string
	IdempotencyKey string
	Err            error
}

func (e *MutationTransportUncertainError) Error() string {
	return fmt.Sprintf(
		"cmux %s transport failed before a response; mutation outcome is uncertain",
		e.Operation,
	)
}

func (e *MutationTransportUncertainError) Unwrap() error { return e.Err }

func (e *MutationTransportUncertainError) Recovery() string {
	return "inspect_state_then_retry_with_new_key"
}

type ProtocolError struct {
	Message string
}

func (e *ProtocolError) Error() string { return "cmux protocol: " + e.Message }
func (e *ProtocolError) Is(target error) bool {
	return target == ErrProtocol
}
