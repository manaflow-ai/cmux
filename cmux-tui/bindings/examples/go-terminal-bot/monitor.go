package terminalbot

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

type monitorMessage struct {
	scope     string
	attempt   int
	output    []byte
	event     cmux.Event
	err       error
	exited    bool
	reconnect bool
}

type taskMonitor struct {
	bot      *Bot
	surface  cmux.ID
	marker   *completionMarker
	messages chan monitorMessage
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

func (bot *Bot) startMonitor(
	ctx context.Context,
	surface cmux.ID,
	deltas *cmux.Stream,
	bytes *cmux.Stream,
	marker *completionMarker,
) *taskMonitor {
	monitorCtx, cancel := context.WithCancel(ctx)
	monitor := &taskMonitor{
		bot:      bot,
		surface:  surface,
		marker:   marker,
		messages: make(chan monitorMessage, 128),
		cancel:   cancel,
	}
	monitor.wg.Add(2)
	go monitor.consumeDeltas(monitorCtx, deltas)
	go monitor.consumeBytes(monitorCtx, bytes)
	return monitor
}

func (monitor *taskMonitor) Close() {
	monitor.cancel()
	monitor.wg.Wait()
}

func (monitor *taskMonitor) waitForMarker(
	ctx context.Context,
	result *Result,
) (int, error) {
	for {
		select {
		case <-ctx.Done():
			return 0, context.Cause(ctx)
		case message := <-monitor.messages:
			if status, found, err := monitor.apply(result, message); found || err != nil {
				return status, err
			}
			if message.exited {
				return 0, errors.New("terminal exited before completion marker")
			}
		}
	}
}

func (monitor *taskMonitor) waitForExit(ctx context.Context, result *Result) error {
	for {
		select {
		case <-ctx.Done():
			return context.Cause(ctx)
		case message := <-monitor.messages:
			_, _, err := monitor.apply(result, message)
			if err != nil {
				return err
			}
			if message.exited {
				return nil
			}
		}
	}
}

func (monitor *taskMonitor) apply(
	result *Result,
	message monitorMessage,
) (status int, markerFound bool, err error) {
	if message.reconnect {
		result.Reconnects++
		if monitor.bot.config.Observer != nil {
			monitor.bot.config.Observer.Reconnect(
				message.scope,
				message.attempt,
				message.err,
			)
		}
		return 0, false, nil
	}
	if message.event != nil {
		result.EventNames = append(result.EventNames, message.event.EventName())
		if monitor.bot.config.Observer != nil {
			monitor.bot.config.Observer.Event(message.event)
		}
	}
	if len(message.output) > 0 {
		result.Output = string(appendLimited(
			[]byte(result.Output),
			message.output,
			monitor.bot.config.MaxOutputBytes,
		))
		if monitor.bot.config.Output != nil {
			if _, writeErr := monitor.bot.config.Output.Write(message.output); writeErr != nil {
				return 0, false, fmt.Errorf("write observed output: %w", writeErr)
			}
		}
		if monitor.bot.config.Observer != nil {
			monitor.bot.config.Observer.Output(message.output)
		}
		if status, found := monitor.marker.consume(message.output); found {
			return status, true, nil
		}
	}
	if message.err != nil {
		return 0, false, message.err
	}
	return 0, false, nil
}

func (monitor *taskMonitor) consumeDeltas(ctx context.Context, stream *cmux.Stream) {
	defer monitor.wg.Done()
	defer func() {
		if stream != nil {
			_ = stream.Close()
		}
	}()

	for reconnect := 0; ; {
		event, err := stream.RecvDelta(ctx)
		if err == nil {
			if !monitor.send(ctx, monitorMessage{event: event}) {
				return
			}
			switch value := event.(type) {
			case cmux.SurfaceExitedEvent:
				if value.Surface == monitor.surface {
					monitor.send(ctx, monitorMessage{exited: true})
					return
				}
			case cmux.OverflowEvent:
				err = fmt.Errorf("delta subscription overflow: %s", value.Error)
			default:
				continue
			}
		}
		if ctx.Err() != nil {
			return
		}
		if reconnect >= monitor.bot.config.RetryLimit || (!isRetryable(err) &&
			!errors.Is(err, io.EOF) &&
			!errors.Is(err, cmux.ErrBufferFull)) {
			monitor.send(ctx, monitorMessage{
				err: fmt.Errorf("delta subscription ended: %w", err),
			})
			return
		}
		reconnect++
		monitor.send(ctx, monitorMessage{
			scope:     "events",
			attempt:   reconnect,
			err:       err,
			reconnect: true,
		})
		_ = stream.Close()
		stream, err = monitor.bot.openDeltaStream(ctx)
		if err != nil {
			monitor.send(ctx, monitorMessage{err: err})
			return
		}
	}
}

func (monitor *taskMonitor) consumeBytes(ctx context.Context, stream *cmux.Stream) {
	defer monitor.wg.Done()
	defer func() {
		if stream != nil {
			_ = stream.Close()
		}
	}()

	for reconnect := 0; ; {
		event, err := stream.RecvByte(ctx)
		if err == nil {
			if !monitor.send(ctx, monitorMessage{event: event}) {
				return
			}
			switch value := event.(type) {
			case cmux.OutputEvent:
				err = monitor.decodeAndSend(ctx, value.Data)
				if err == nil {
					continue
				}
			case cmux.VTStateEvent:
				err = monitor.decodeAndSend(ctx, value.Data)
				if err == nil {
					continue
				}
			case cmux.ResizedEvent:
				replay := value.Replay
				if replay == nil {
					replay = value.Data
				}
				if replay != nil {
					err = monitor.decodeAndSend(ctx, *replay)
					if err != nil {
						break
					}
				}
				continue
			case cmux.DetachedEvent:
				monitor.send(ctx, monitorMessage{exited: true})
				return
			case cmux.OverflowEvent:
				err = fmt.Errorf("byte attachment overflow: %s", value.Error)
			default:
				continue
			}
		}
		if ctx.Err() != nil {
			return
		}
		if reconnect >= monitor.bot.config.RetryLimit || (!isRetryable(err) &&
			!errors.Is(err, io.EOF) &&
			!errors.Is(err, cmux.ErrBufferFull)) {
			monitor.send(ctx, monitorMessage{
				err: fmt.Errorf("byte attachment ended: %w", err),
			})
			return
		}
		reconnect++
		monitor.send(ctx, monitorMessage{
			scope:     "output",
			attempt:   reconnect,
			err:       err,
			reconnect: true,
		})
		_ = stream.Close()
		stream, err = monitor.bot.openByteStream(ctx, monitor.surface)
		if err != nil {
			monitor.send(ctx, monitorMessage{err: err})
			return
		}
	}
}

func (monitor *taskMonitor) decodeAndSend(ctx context.Context, data cmux.Base64) error {
	decoded, err := cmux.DecodeBase64(data)
	if err != nil {
		return fmt.Errorf("%w: decode terminal output: %v", cmux.ErrDecode, err)
	}
	if !monitor.send(ctx, monitorMessage{output: decoded}) {
		return context.Cause(ctx)
	}
	return nil
}

func (monitor *taskMonitor) send(ctx context.Context, message monitorMessage) bool {
	select {
	case <-ctx.Done():
		return false
	case monitor.messages <- message:
		return true
	}
}
