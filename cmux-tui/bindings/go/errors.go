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

type ProtocolError struct {
	Message string
}

func (e *ProtocolError) Error() string { return "cmux protocol: " + e.Message }
func (e *ProtocolError) Is(target error) bool {
	return target == ErrProtocol
}
